//! Local internal contract proposals; this does not sign or send agreements.
use super::{actor, db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};

pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS contract_proposals(id TEXT PRIMARY KEY, customer TEXT NOT NULL REFERENCES customers(id), title TEXT NOT NULL, terms TEXT NOT NULL, creator TEXT NOT NULL REFERENCES actors(id), state TEXT NOT NULL, version INTEGER NOT NULL, created INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS contract_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL UNIQUE, request_hash BLOB NOT NULL, actor TEXT NOT NULL REFERENCES actors(id), contract TEXT NOT NULL REFERENCES contract_proposals(id), action TEXT NOT NULL, created INTEGER NOT NULL);")
}
fn valid_id(s: &str) -> bool {
    (16..=80).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn roles(db: &Connection, who: &str) -> Result<Vec<String>, ApiError> {
    let mut stmt = db
        .prepare("SELECT role FROM actor_roles WHERE actor=?1")
        .map_err(db_error)?;
    let rows = stmt.query_map([who], |r| r.get(0)).map_err(db_error)?;
    rows.collect::<Result<Vec<String>, _>>().map_err(db_error)
}
fn access(db: &Connection, who: &str) -> Result<Vec<String>, ApiError> {
    let roles = roles(db, who)?;
    if !monastack_core::access::can_manage_sales(&roles) {
        return Err(err(StatusCode::FORBIDDEN, "sales access required"));
    }
    Ok(roles)
}
fn replay(tx: &Transaction<'_>, op: &str, payload: &str, who: &str) -> Result<bool, ApiError> {
    let old: Option<(Vec<u8>, String)> = tx
        .query_row(
            "SELECT request_hash,actor FROM contract_audit WHERE op=?1",
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
    tx.execute("INSERT INTO contract_audit(op,request_hash,actor,contract,action,created) VALUES (?1,?2,?3,?4,?5,?6)",params![op,hash(payload),who,id,action,now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct Contract {
    id: String,
    customer: String,
    customer_name: String,
    title: String,
    terms: String,
    creator: String,
    state: String,
    version: i64,
}
pub async fn list(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<Contract>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    access(&db, &who)?;
    let mut stmt=db.prepare("SELECT x.id,x.customer,c.name,x.title,x.terms,x.creator,x.state,x.version FROM contract_proposals x JOIN customers c ON c.id=x.customer ORDER BY x.rowid DESC LIMIT 200").map_err(db_error)?;
    let rows = stmt
        .query_map([], |r| {
            Ok(Contract {
                id: r.get(0)?,
                customer: r.get(1)?,
                customer_name: r.get(2)?,
                title: r.get(3)?,
                terms: r.get(4)?,
                creator: r.get(5)?,
                state: r.get(6)?,
                version: r.get(7)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
pub async fn capabilities(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    let r = access(&db, &who)?;
    Ok(Json(
        serde_json::json!({"can_decide":r.iter().any(|x|x=="org-admin")}),
    ))
}
#[derive(Deserialize, Serialize)]
pub struct Proposal {
    id: String,
    customer: String,
    title: String,
    terms: String,
    op: String,
}
pub async fn create(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(input): Json<Proposal>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.id)
        || !valid_id(&input.customer)
        || !valid_id(&input.op)
        || !monastack_core::access::valid_contract_proposal(&input.title, &input.terms)
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid proposal"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;

    access(&tx, &who)?;
    let payload = format!("propose:{}", serde_json::to_string(&input).unwrap());
    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let found: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM customers WHERE id=?1)",
            [&input.customer],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !found {
        return Err(err(StatusCode::NOT_FOUND, "customer not found"));
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM contract_proposals WHERE id=?1)",
            [&input.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "proposal id exists"));
    }
    tx.execute(
        "INSERT INTO contract_proposals VALUES (?1,?2,?3,?4,?5,'proposed',1,?6)",
        params![
            input.id,
            input.customer,
            input.title,
            input.terms,
            who,
            now()
        ],
    )
    .map_err(db_error)?;
    audit(&tx, &input.op, &payload, &who, &input.id, "proposed")?;
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
    Json(input): Json<Decision>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.op) || !matches!(input.action.as_str(), "approve" | "reject" | "withdraw") {
        return Err(err(StatusCode::BAD_REQUEST, "invalid decision"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;

    let r = access(&tx, &who)?;
    let row: Option<(String, String, i64)> = tx
        .query_row(
            "SELECT creator,state,version FROM contract_proposals WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (creator, current, version) =
        row.ok_or(err(StatusCode::NOT_FOUND, "proposal not found"))?;
    if (input.action == "withdraw" && creator != who)
        || (input.action != "withdraw"
            && !monastack_core::access::can_decide_contract(&r, &who, &creator))
    {
        return Err(err(StatusCode::FORBIDDEN, "decision not permitted"));
    }
    let payload = format!("decision:{}:{}", id, serde_json::to_string(&input).unwrap());
    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    if version != input.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale proposal version"));
    }
    let next = monastack_core::access::contract_next_state(&current, &input.action)
        .ok_or(err(StatusCode::CONFLICT, "invalid proposal transition"))?;
    tx.execute(
        "UPDATE contract_proposals SET state=?1,version=version+1 WHERE id=?2",
        params![next, id],
    )
    .map_err(db_error)?;
    audit(&tx, &input.op, &payload, &who, &id, &input.action)?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::OK)
}
#[derive(Serialize)]
pub struct Event {
    actor: String,
    action: String,
    created: i64,
}
pub async fn history(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Vec<Event>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    access(&db, &who)?;
    let exists: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM contract_proposals WHERE id=?1)",
            [&id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !exists {
        return Err(err(StatusCode::NOT_FOUND, "proposal not found"));
    }
    let mut stmt = db
        .prepare("SELECT actor,action,created FROM contract_audit WHERE contract=?1 ORDER BY seq")
        .map_err(db_error)?;
    let rows = stmt
        .query_map([id], |r| {
            Ok(Event {
                actor: r.get(0)?,
                action: r.get(1)?,
                created: r.get(2)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
