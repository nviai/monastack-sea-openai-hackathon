//! Internal payment authorization records only. No payment executor exists.
use super::{actor, db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};
pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS payment_authorizations(id TEXT PRIMARY KEY, expense TEXT NOT NULL REFERENCES expenses(id), requester TEXT NOT NULL REFERENCES actors(id), state TEXT NOT NULL, version INTEGER NOT NULL, created INTEGER NOT NULL); CREATE UNIQUE INDEX IF NOT EXISTS active_payment_per_expense ON payment_authorizations(expense) WHERE state IN ('pending','approved_waiting'); CREATE TABLE IF NOT EXISTS payment_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL UNIQUE, request_hash BLOB NOT NULL, actor TEXT NOT NULL REFERENCES actors(id), payment TEXT NOT NULL REFERENCES payment_authorizations(id), action TEXT NOT NULL, created INTEGER NOT NULL);")
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
    let rows = stmt
        .query_map([who], |r| r.get::<_, String>(0))
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    if !monastack_core::access::can_access_finance(&rows) {
        return Err(err(StatusCode::FORBIDDEN, "finance access denied"));
    }
    Ok(rows)
}
pub async fn capabilities(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    let current = roles(&db, &who)?;
    Ok(Json(
        serde_json::json!({"can_approve":current.iter().any(|r|r=="org-admin")}),
    ))
}
fn replay(tx: &Transaction<'_>, op: &str, payload: &str, who: &str) -> Result<bool, ApiError> {
    let old: Option<(Vec<u8>, String)> = tx
        .query_row(
            "SELECT request_hash,actor FROM payment_audit WHERE op=?1",
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
    tx.execute("INSERT INTO payment_audit(op,request_hash,actor,payment,action,created) VALUES (?1,?2,?3,?4,?5,?6)",params![op,hash(payload),who,id,action,now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct Payment {
    id: String,
    expense: String,
    description: String,
    minor: i64,
    currency: String,
    expense_creator: String,
    requester: String,
    state: String,
    version: i64,
}
pub async fn list(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<Payment>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    roles(&db, &who)?;
    let mut stmt=db.prepare("SELECT p.id,p.expense,e.description,e.minor,e.currency,e.creator,p.requester,p.state,p.version FROM payment_authorizations p JOIN expenses e ON e.id=p.expense ORDER BY p.rowid DESC LIMIT 200").map_err(db_error)?;
    let rows = stmt
        .query_map([], |r| {
            Ok(Payment {
                id: r.get(0)?,
                expense: r.get(1)?,
                description: r.get(2)?,
                minor: r.get(3)?,
                currency: r.get(4)?,
                expense_creator: r.get(5)?,
                requester: r.get(6)?,
                state: r.get(7)?,
                version: r.get(8)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
#[derive(Deserialize, Serialize)]
pub struct NewPayment {
    id: String,
    expense: String,
    op: String,
}
pub async fn create(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(input): Json<NewPayment>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.id) || !valid_id(&input.expense) || !valid_id(&input.op) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid authorization"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    roles(&tx, &who)?;
    let payload = format!("create:{}", serde_json::to_string(&input).unwrap());

    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let state: Option<String> = tx
        .query_row(
            "SELECT state FROM expenses WHERE id=?1",
            [&input.expense],
            |r| r.get(0),
        )
        .optional()
        .map_err(db_error)?;
    if state.ok_or(err(StatusCode::NOT_FOUND, "expense not found"))? != "approved" {
        return Err(err(StatusCode::CONFLICT, "expense must be approved"));
    }
    let id_exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM payment_authorizations WHERE id=?1)",
            [&input.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    let active:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM payment_authorizations WHERE expense=?1 AND state IN ('pending','approved_waiting'))",[&input.expense],|r|r.get(0)).map_err(db_error)?;
    if id_exists || active {
        return Err(err(StatusCode::CONFLICT, "authorization already exists"));
    }
    tx.execute(
        "INSERT INTO payment_authorizations VALUES (?1,?2,?3,'pending',1,?4)",
        params![input.id, input.expense, who, now()],
    )
    .map_err(db_error)?;
    audit(&tx, &input.op, &payload, &who, &input.id, "requested")?;
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
    if !valid_id(&input.op)
        || !matches!(
            input.action.as_str(),
            "approve" | "reject" | "withdraw" | "revoke"
        )
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid decision"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let roles = roles(&tx, &who)?;
    let payload = format!("decision:{}:{}", id, serde_json::to_string(&input).unwrap());

    let row:Option<(String,String,String,i64)>=tx.query_row("SELECT p.requester,e.creator,p.state,p.version FROM payment_authorizations p JOIN expenses e ON e.id=p.expense WHERE p.id=?1",[&id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional().map_err(db_error)?;
    let (requester, expense_creator, state, version) =
        row.ok_or(err(StatusCode::NOT_FOUND, "authorization not found"))?;
    if (input.action == "withdraw" && who != requester)
        || (input.action != "withdraw"
            && !monastack_core::access::can_decide_payment(
                &roles,
                &who,
                &requester,
                &expense_creator,
            ))
    {
        return Err(err(StatusCode::FORBIDDEN, "decision not permitted"));
    }
    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    if version != input.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale authorization version"));
    }
    let next = monastack_core::access::payment_next_state(&state, &input.action).ok_or(err(
        StatusCode::CONFLICT,
        "invalid authorization transition",
    ))?;
    tx.execute(
        "UPDATE payment_authorizations SET state=?1,version=version+1 WHERE id=?2",
        params![next, id],
    )
    .map_err(db_error)?;
    audit(&tx, &input.op, &payload, &who, &id, &input.action)?;
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
    roles(&db, &who)?;
    let exists: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM payment_authorizations WHERE id=?1)",
            [&id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !exists {
        return Err(err(StatusCode::NOT_FOUND, "authorization not found"));
    }
    let mut stmt = db
        .prepare("SELECT actor,action,created FROM payment_audit WHERE payment=?1 ORDER BY seq")
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
