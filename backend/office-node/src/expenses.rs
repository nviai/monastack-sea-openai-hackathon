//! Online-only approval records. No payments or ledger posting occur here.
use super::{actor, db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};
pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS expenses(id TEXT PRIMARY KEY, description TEXT NOT NULL, minor INTEGER NOT NULL, currency TEXT NOT NULL, creator TEXT NOT NULL REFERENCES actors(id), state TEXT NOT NULL, version INTEGER NOT NULL, created INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS expense_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL UNIQUE, request_hash BLOB NOT NULL, actor TEXT NOT NULL REFERENCES actors(id), expense TEXT NOT NULL REFERENCES expenses(id), action TEXT NOT NULL, created INTEGER NOT NULL);")
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
            "SELECT request_hash,actor FROM expense_audit WHERE op=?1",
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
    tx.execute("INSERT INTO expense_audit(op,request_hash,actor,expense,action,created) VALUES (?1,?2,?3,?4,?5,?6)",params![op,hash(payload),who,id,action,now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct Expense {
    id: String,
    description: String,
    minor: i64,
    currency: String,
    creator: String,
    state: String,
    version: i64,
}
pub async fn list(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<Expense>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    access(&db, &who)?;
    let mut stmt=db.prepare("SELECT id,description,minor,currency,creator,state,version FROM expenses ORDER BY rowid DESC LIMIT 200").map_err(db_error)?;
    let rows = stmt
        .query_map([], |r| {
            Ok(Expense {
                id: r.get(0)?,
                description: r.get(1)?,
                minor: r.get(2)?,
                currency: r.get(3)?,
                creator: r.get(4)?,
                state: r.get(5)?,
                version: r.get(6)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
#[derive(Deserialize, Serialize)]
pub struct NewExpense {
    id: String,
    description: String,
    minor: i64,
    currency: String,
    op: String,
}
pub async fn create(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(e): Json<NewExpense>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&e.id)
        || !valid_id(&e.op)
        || !monastack_core::access::valid_expense(&e.description, e.minor, &e.currency)
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid expense"));
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
            "SELECT EXISTS(SELECT 1 FROM expenses WHERE id=?1)",
            [&e.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "expense id exists"));
    }
    tx.execute(
        "INSERT INTO expenses VALUES (?1,?2,?3,?4,?5,'proposed',1,?6)",
        params![e.id, e.description, e.minor, e.currency, who, now()],
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
    if !valid_id(&d.op) || !matches!(d.action.as_str(), "approve" | "reject" | "withdraw") {
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
            "SELECT creator,state,version FROM expenses WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (creator, state, version) = row.ok_or(err(StatusCode::NOT_FOUND, "expense not found"))?;
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
        return Err(err(StatusCode::CONFLICT, "stale expense version"));
    }
    if state != "proposed" {
        return Err(err(StatusCode::CONFLICT, "expense already decided"));
    }
    let status = match d.action.as_str() {
        "approve" => "approved",
        "reject" => "rejected",
        _ => "withdrawn",
    };
    tx.execute(
        "UPDATE expenses SET state=?1,version=version+1 WHERE id=?2",
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
            "SELECT EXISTS(SELECT 1 FROM expenses WHERE id=?1)",
            [&id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !exists {
        return Err(err(StatusCode::NOT_FOUND, "expense not found"));
    }
    let mut stmt = db
        .prepare("SELECT actor,action,created FROM expense_audit WHERE expense=?1 ORDER BY seq")
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
