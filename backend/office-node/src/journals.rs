//! Online-only two-line journal records. Posting does not execute payments.
use super::{actor, db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};
pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS journal_entries(id TEXT PRIMARY KEY, description TEXT NOT NULL, debit TEXT NOT NULL, credit TEXT NOT NULL, minor INTEGER NOT NULL, currency TEXT NOT NULL, creator TEXT NOT NULL REFERENCES actors(id), state TEXT NOT NULL, version INTEGER NOT NULL, created INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS journal_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL UNIQUE, request_hash BLOB NOT NULL, actor TEXT NOT NULL REFERENCES actors(id), journal TEXT NOT NULL REFERENCES journal_entries(id), action TEXT NOT NULL, created INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS journal_reversals(reversal TEXT PRIMARY KEY REFERENCES journal_entries(id), original TEXT NOT NULL REFERENCES journal_entries(id)); CREATE INDEX IF NOT EXISTS journal_reversals_original ON journal_reversals(original);")
}
fn roles(db: &Connection, who: &str) -> Result<Vec<String>, ApiError> {
    let mut stmt = db
        .prepare("SELECT role FROM actor_roles WHERE actor=?1")
        .map_err(db_error)?;
    let rows = stmt
        .query_map([who], |r| r.get::<_, String>(0))
        .map_err(db_error)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(db_error)
}
fn access(db: &Connection, who: &str) -> Result<Vec<String>, ApiError> {
    let r = roles(db, who)?;
    if !monastack_core::access::can_access_finance(&r) {
        return Err(err(StatusCode::FORBIDDEN, "finance access denied"));
    }
    Ok(r)
}
fn valid_id(s: &str) -> bool {
    s.len() >= 16
        && s.len() <= 80
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn replay(tx: &Transaction<'_>, op: &str, payload: &str, who: &str) -> Result<bool, ApiError> {
    let old: Option<(Vec<u8>, String)> = tx
        .query_row(
            "SELECT request_hash,actor FROM journal_audit WHERE op=?1",
            [op],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(db_error)?;
    match old {
        None => Ok(false),
        Some((digest, owner)) if digest == hash(payload) && owner == who => Ok(true),
        Some(_) => Err(err(StatusCode::CONFLICT, "operation id conflict")),
    }
}
fn audit(
    tx: &Transaction<'_>,
    op: &str,
    payload: &str,
    who: &str,
    id: &str,
    action: &str,
) -> Result<(), ApiError> {
    tx.execute("INSERT INTO journal_audit(op,request_hash,actor,journal,action,created) VALUES (?1,?2,?3,?4,?5,?6)",params![op,hash(payload),who,id,action,now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct Journal {
    id: String,
    description: String,
    debit: String,
    credit: String,
    minor: i64,
    currency: String,
    creator: String,
    state: String,
    version: i64,
    reverses: Option<String>,
    reversed: bool,
}
pub async fn list(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<Journal>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    access(&db, &who)?;
    let mut stmt=db.prepare("SELECT j.id,j.description,j.debit,j.credit,j.minor,j.currency,j.creator,j.state,j.version,r.original,EXISTS(SELECT 1 FROM journal_reversals r2 JOIN journal_entries j2 ON j2.id=r2.reversal WHERE r2.original=j.id AND j2.state='posted') FROM journal_entries j LEFT JOIN journal_reversals r ON r.reversal=j.id ORDER BY j.rowid DESC LIMIT 200").map_err(db_error)?;
    let rows = stmt
        .query_map([], |r| {
            Ok(Journal {
                id: r.get(0)?,
                description: r.get(1)?,
                debit: r.get(2)?,
                credit: r.get(3)?,
                minor: r.get(4)?,
                currency: r.get(5)?,
                creator: r.get(6)?,
                state: r.get(7)?,
                version: r.get(8)?,
                reverses: r.get(9)?,
                reversed: r.get(10)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
#[derive(Deserialize, Serialize)]
pub struct NewJournal {
    id: String,
    description: String,
    debit: String,
    credit: String,
    minor: i64,
    currency: String,
    op: String,
}
pub async fn create(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(e): Json<NewJournal>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&e.id)
        || !valid_id(&e.op)
        || !monastack_core::access::valid_journal(
            &e.description,
            &e.debit,
            &e.credit,
            e.minor,
            &e.currency,
        )
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid journal"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    access(&tx, &who)?;
    let payload = serde_json::to_string(&e).unwrap();

    if replay(&tx, &e.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM journal_entries WHERE id=?1)",
            [&e.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "journal id exists"));
    }
    tx.execute(
        "INSERT INTO journal_entries VALUES (?1,?2,?3,?4,?5,?6,?7,'proposed',1,?8)",
        params![
            e.id,
            e.description,
            e.debit,
            e.credit,
            e.minor,
            e.currency,
            who,
            now()
        ],
    )
    .map_err(db_error)?;
    audit(&tx, &e.op, &payload, &who, &e.id, "proposed")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}
#[derive(Deserialize, Serialize)]
pub struct Decision {
    action: String,
    expected_version: i64,
    op: String,
}
pub async fn decision(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(d): Json<Decision>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&d.op) || !matches!(d.action.as_str(), "post" | "reject" | "withdraw") {
        return Err(err(StatusCode::BAD_REQUEST, "invalid decision"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let roles = access(&tx, &who)?;
    let payload = format!("{}:{}", id, serde_json::to_string(&d).unwrap());

    let row: Option<(String, String, i64)> = tx
        .query_row(
            "SELECT creator,state,version FROM journal_entries WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (creator, state, version) = row.ok_or(err(StatusCode::NOT_FOUND, "journal not found"))?;
    if (d.action == "withdraw" && who != creator)
        || (d.action != "withdraw"
            && !monastack_core::access::can_decide_expense(&roles, &who, &creator))
    {
        return Err(err(StatusCode::FORBIDDEN, "decision not permitted"));
    }
    if replay(&tx, &d.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    if version != d.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale journal version"));
    }
    if state != "proposed" {
        return Err(err(StatusCode::CONFLICT, "journal already decided"));
    }
    if d.action == "post" {
        let original: Option<String> = tx
            .query_row(
                "SELECT original FROM journal_reversals WHERE reversal=?1",
                [&id],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_error)?;
        if let Some(original) = original {
            let already_posted: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM journal_reversals r JOIN journal_entries j ON j.id=r.reversal WHERE r.original=?1 AND j.state='posted')", [&original], |r| r.get(0)).map_err(db_error)?;
            if already_posted {
                return Err(err(StatusCode::CONFLICT, "original already reversed"));
            }
        }
    }
    let status = match d.action.as_str() {
        "post" => "posted",
        "reject" => "rejected",
        _ => "withdrawn",
    };
    tx.execute(
        "UPDATE journal_entries SET state=?1,version=version+1 WHERE id=?2",
        params![status, id],
    )
    .map_err(db_error)?;
    audit(&tx, &d.op, &payload, &who, &id, &d.action)?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::OK)
}
#[derive(Serialize)]
pub struct AuditEvent {
    actor: String,
    action: String,
    created: i64,
}
pub async fn history(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Vec<AuditEvent>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    access(&db, &who)?;
    let exists: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM journal_entries WHERE id=?1)",
            [&id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !exists {
        return Err(err(StatusCode::NOT_FOUND, "journal not found"));
    }
    let mut stmt = db
        .prepare("SELECT actor,action,created FROM journal_audit WHERE journal=?1 ORDER BY seq")
        .map_err(db_error)?;
    let rows = stmt
        .query_map([id], |r| {
            Ok(AuditEvent {
                actor: r.get(0)?,
                action: r.get(1)?,
                created: r.get(2)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}

#[derive(Deserialize, Serialize)]
pub struct Reversal {
    id: String,
    op: String,
}
pub async fn reverse(
    State(state): State<Db>,
    Path(original): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Reversal>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.id) || !valid_id(&input.op) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid reversal"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    access(&tx, &who)?;
    let payload = format!(
        "reverse:{}:{}",
        original,
        serde_json::to_string(&input).unwrap()
    );

    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let row: Option<(String, String, i64, String, String)> = tx
        .query_row(
            "SELECT debit,credit,minor,currency,state FROM journal_entries WHERE id=?1",
            [&original],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (debit, credit, minor, currency, state) =
        row.ok_or(err(StatusCode::NOT_FOUND, "journal not found"))?;
    if state != "posted" {
        return Err(err(
            StatusCode::CONFLICT,
            "only posted entries can be reversed",
        ));
    }
    let is_reversal: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM journal_reversals WHERE reversal=?1)",
            [&original],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if is_reversal {
        return Err(err(
            StatusCode::CONFLICT,
            "reversing a reversal is not supported",
        ));
    }
    let already:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM journal_reversals r JOIN journal_entries j ON j.id=r.reversal WHERE r.original=?1 AND j.state='posted')",[&original],|r|r.get(0)).map_err(db_error)?;
    if already {
        return Err(err(StatusCode::CONFLICT, "original already reversed"));
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM journal_entries WHERE id=?1)",
            [&input.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "journal id exists"));
    }
    tx.execute(
        "INSERT INTO journal_entries VALUES (?1,?2,?3,?4,?5,?6,?7,'proposed',1,?8)",
        params![
            input.id,
            format!("Reversal of {original}"),
            credit,
            debit,
            minor,
            currency,
            who,
            now()
        ],
    )
    .map_err(db_error)?;
    tx.execute(
        "INSERT INTO journal_reversals(reversal,original) VALUES (?1,?2)",
        params![input.id, original],
    )
    .map_err(db_error)?;
    audit(
        &tx,
        &input.op,
        &payload,
        &who,
        &input.id,
        &format!("reversal_proposed:{original}"),
    )?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}

#[derive(Serialize)]
pub struct Balance {
    account: String,
    currency: String,
    net_debit_minor: String,
}
fn posted_balances(
    db: &Connection,
) -> Result<std::collections::BTreeMap<(String, String), i128>, ApiError> {
    use std::collections::BTreeMap;
    let mut totals: BTreeMap<(String, String), i128> = BTreeMap::new();
    let mut stmt = db
        .prepare("SELECT debit,credit,minor,currency FROM journal_entries WHERE state='posted'")
        .map_err(db_error)?;
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, String>(3)?,
            ))
        })
        .map_err(db_error)?;
    for row in rows {
        let (debit, credit, minor, currency) = row.map_err(db_error)?;
        let d = totals.entry((currency.clone(), debit)).or_default();
        *d = d
            .checked_add(i128::from(minor))
            .ok_or(err(StatusCode::INTERNAL_SERVER_ERROR, "balance overflow"))?;
        let c = totals.entry((currency, credit)).or_default();
        *c = c
            .checked_sub(i128::from(minor))
            .ok_or(err(StatusCode::INTERNAL_SERVER_ERROR, "balance overflow"))?;
    }
    Ok(totals)
}
pub async fn balances(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<Balance>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    access(&db, &who)?;
    let totals = posted_balances(&db)?;
    Ok(Json(
        totals
            .into_iter()
            .map(|((currency, account), value)| Balance {
                account,
                currency,
                net_debit_minor: value.to_string(),
            })
            .collect(),
    ))
}

#[derive(Serialize)]
pub struct TrialAccount {
    account: String,
    debit_minor: String,
    credit_minor: String,
}
#[derive(Serialize)]
pub struct TrialCurrency {
    currency: String,
    debit_total_minor: String,
    credit_total_minor: String,
    accounts: Vec<TrialAccount>,
}
pub async fn trial_balance(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<TrialCurrency>>, ApiError> {
    use std::collections::BTreeMap;
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    access(&db, &who)?;
    let mut groups: BTreeMap<String, (i128, i128, Vec<TrialAccount>)> = BTreeMap::new();
    for ((currency, account), value) in posted_balances(&db)? {
        let debit = value.max(0);
        let credit = if value < 0 {
            value
                .checked_neg()
                .ok_or(err(StatusCode::INTERNAL_SERVER_ERROR, "balance overflow"))?
        } else {
            0
        };
        let group = groups.entry(currency).or_default();
        group.0 = group
            .0
            .checked_add(debit)
            .ok_or(err(StatusCode::INTERNAL_SERVER_ERROR, "balance overflow"))?;
        group.1 = group
            .1
            .checked_add(credit)
            .ok_or(err(StatusCode::INTERNAL_SERVER_ERROR, "balance overflow"))?;
        group.2.push(TrialAccount {
            account,
            debit_minor: debit.to_string(),
            credit_minor: credit.to_string(),
        });
    }
    Ok(Json(
        groups
            .into_iter()
            .map(|(currency, (debit, credit, accounts))| TrialCurrency {
                currency,
                debit_total_minor: debit.to_string(),
                credit_total_minor: credit.to_string(),
                accounts,
            })
            .collect(),
    ))
}
