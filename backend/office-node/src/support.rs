//! Local support cases linked to the existing customer authority.
use super::{actor, db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};

pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS support_cases(id TEXT PRIMARY KEY, customer TEXT NOT NULL REFERENCES customers(id), title TEXT NOT NULL, status TEXT NOT NULL, version INTEGER NOT NULL, created_by TEXT NOT NULL REFERENCES actors(id), created INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS support_case_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL UNIQUE, request_hash BLOB NOT NULL, actor TEXT NOT NULL REFERENCES actors(id), support_case TEXT NOT NULL REFERENCES support_cases(id), action TEXT NOT NULL, created INTEGER NOT NULL);")
}
fn valid_id(s: &str) -> bool {
    (16..=80).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn can_manage(db: &Connection, who: &str) -> Result<bool, ApiError> {
    let mut stmt = db
        .prepare("SELECT role FROM actor_roles WHERE actor=?1")
        .map_err(db_error)?;
    let roles = stmt
        .query_map([who], |r| r.get::<_, String>(0))
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    Ok(monastack_core::access::can_manage_support(&roles))
}
fn support_access(db: &Connection, who: &str) -> Result<(), ApiError> {
    if !can_manage(db, who)? {
        return Err(err(StatusCode::FORBIDDEN, "support access required"));
    }
    Ok(())
}
pub async fn capabilities(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    super::customers::authorized(&db, &who)?;
    Ok(Json(
        serde_json::json!({"can_manage":can_manage(&db, &who)?}),
    ))
}
fn replay(tx: &Transaction<'_>, op: &str, payload: &str, who: &str) -> Result<bool, ApiError> {
    let old: Option<(Vec<u8>, String)> = tx
        .query_row(
            "SELECT request_hash,actor FROM support_case_audit WHERE op=?1",
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
    tx.execute("INSERT INTO support_case_audit(op,request_hash,actor,support_case,action,created) VALUES (?1,?2,?3,?4,?5,?6)", params![op, hash(payload), who, id, action, now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct SupportCase {
    id: String,
    customer: String,
    customer_name: String,
    title: String,
    status: String,
    version: i64,
    created_by: String,
}
pub async fn list(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<SupportCase>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    super::customers::authorized(&db, &who)?;
    let mut stmt = db.prepare("SELECT o.id,o.customer,c.name,o.title,o.status,o.version,o.created_by FROM support_cases o JOIN customers c ON c.id=o.customer ORDER BY o.rowid DESC LIMIT 200").map_err(db_error)?;
    let rows = stmt
        .query_map([], |r| {
            Ok(SupportCase {
                id: r.get(0)?,
                customer: r.get(1)?,
                customer_name: r.get(2)?,
                title: r.get(3)?,
                status: r.get(4)?,
                version: r.get(5)?,
                created_by: r.get(6)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
#[derive(Deserialize, Serialize)]
pub struct NewSupportCase {
    id: String,
    customer: String,
    title: String,
    op: String,
}
pub async fn create(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(input): Json<NewSupportCase>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.id)
        || !valid_id(&input.customer)
        || !valid_id(&input.op)
        || input.title.trim().is_empty()
        || input.title.len() > 200
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid support case"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    support_access(&tx, &who)?;
    let payload = format!("create:{}", serde_json::to_string(&input).unwrap());

    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM customers WHERE id=?1)",
            [&input.customer],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !exists {
        return Err(err(StatusCode::NOT_FOUND, "customer not found"));
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM support_cases WHERE id=?1)",
            [&input.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "support case id exists"));
    }
    tx.execute(
        "INSERT INTO support_cases VALUES (?1,?2,?3,'open',1,?4,?5)",
        params![input.id, input.customer, input.title, who, now()],
    )
    .map_err(db_error)?;
    audit(&tx, &input.op, &payload, &who, &input.id, "created")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}
#[derive(Deserialize, Serialize)]
pub struct Transition {
    to: String,
    expected_version: i64,
    op: String,
}
pub async fn transition(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Transition>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.op) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid operation"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    support_access(&tx, &who)?;
    let payload = format!(
        "transition:{}:{}",
        id,
        serde_json::to_string(&input).unwrap()
    );

    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let row: Option<(String, i64)> = tx
        .query_row(
            "SELECT status,version FROM support_cases WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (stage, version) = row.ok_or(err(StatusCode::NOT_FOUND, "support case not found"))?;
    if version != input.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale support case version"));
    }
    if !monastack_core::access::support_transition(&stage, &input.to) {
        return Err(err(StatusCode::CONFLICT, "invalid support case transition"));
    }
    tx.execute(
        "UPDATE support_cases SET status=?1,version=version+1 WHERE id=?2",
        params![input.to, id],
    )
    .map_err(db_error)?;
    audit(
        &tx,
        &input.op,
        &payload,
        &who,
        &id,
        &format!("status:{}:{}", stage, input.to),
    )?;
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
    super::customers::authorized(&db, &who)?;
    let exists: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM support_cases WHERE id=?1)",
            [&id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !exists {
        return Err(err(StatusCode::NOT_FOUND, "support case not found"));
    }
    let mut stmt = db
        .prepare(
            "SELECT actor,action,created FROM support_case_audit WHERE support_case=?1 ORDER BY seq",
        )
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
