//! Local-only customer records; no email, CRM import or external integrations.
use super::{actor, db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};

pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS customers(id TEXT PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL, notes TEXT NOT NULL, version INTEGER NOT NULL, created_by TEXT NOT NULL REFERENCES actors(id)); CREATE TABLE IF NOT EXISTS customer_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL UNIQUE, request_hash BLOB NOT NULL, actor TEXT NOT NULL REFERENCES actors(id), customer TEXT NOT NULL REFERENCES customers(id), action TEXT NOT NULL, created INTEGER NOT NULL);")
}
pub fn seed_roles(
    tx: &Transaction<'_>,
    actors: &[serde_json::Value],
) -> Result<(), Box<dyn std::error::Error>> {
    let seeded: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='business-roles-v1')",
        [],
        |r| r.get(0),
    )?;
    if !seeded {
        for a in actors {
            if a["kind"] == "human" {
                let id = a["id"].as_str().ok_or("actor id")?;
                for role in a["role"]
                    .as_str()
                    .ok_or("actor role")?
                    .split(',')
                    .map(str::trim)
                {
                    tx.execute(
                        "INSERT OR IGNORE INTO actor_roles VALUES (?1,?2)",
                        params![id, role],
                    )?;
                }
            }
        }
        tx.execute(
            "INSERT INTO metadata VALUES ('business-roles-v1','applied')",
            [],
        )?;
    }
    Ok(())
}
pub(super) fn authorized(db: &Connection, who: &str) -> Result<(), ApiError> {
    let mut stmt = db
        .prepare("SELECT role FROM actor_roles WHERE actor=?1")
        .map_err(db_error)?;
    let roles = stmt
        .query_map([who], |r| r.get::<_, String>(0))
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    if !monastack_core::access::can_access_customers(&roles) {
        return Err(err(StatusCode::FORBIDDEN, "customer access denied"));
    }
    Ok(())
}
fn valid_id(s: &str) -> bool {
    s.len() >= 16
        && s.len() <= 80
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn valid_fields(name: &str, email: &str, notes: &str) -> bool {
    !name.trim().is_empty() && name.len() <= 200 && email.len() <= 320 && notes.len() <= 4000
}
fn replay(tx: &Transaction<'_>, op: &str, payload: &str, who: &str) -> Result<bool, ApiError> {
    let old: Option<(Vec<u8>, String)> = tx
        .query_row(
            "SELECT request_hash,actor FROM customer_audit WHERE op=?1",
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
    tx.execute("INSERT INTO customer_audit(op,request_hash,actor,customer,action,created) VALUES (?1,?2,?3,?4,?5,?6)",params![op,hash(payload),who,id,action,now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct Customer {
    id: String,
    name: String,
    email: String,
    notes: String,
    version: i64,
}
pub async fn list(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<Customer>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    authorized(&db, &who)?;
    let mut stmt = db
        .prepare("SELECT id,name,email,notes,version FROM customers ORDER BY name,id LIMIT 200")
        .map_err(db_error)?;
    let rows = stmt
        .query_map([], |r| {
            Ok(Customer {
                id: r.get(0)?,
                name: r.get(1)?,
                email: r.get(2)?,
                notes: r.get(3)?,
                version: r.get(4)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
pub async fn read(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Customer>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    authorized(&db, &who)?;
    let c = db
        .query_row(
            "SELECT id,name,email,notes,version FROM customers WHERE id=?1",
            [id],
            |r| {
                Ok(Customer {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    email: r.get(2)?,
                    notes: r.get(3)?,
                    version: r.get(4)?,
                })
            },
        )
        .optional()
        .map_err(db_error)?
        .ok_or(err(StatusCode::NOT_FOUND, "customer not found"))?;
    Ok(Json(c))
}
#[derive(Deserialize, Serialize)]
pub struct NewCustomer {
    id: String,
    name: String,
    email: String,
    notes: String,
    op: String,
}
pub async fn create(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(c): Json<NewCustomer>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&c.id) || !valid_id(&c.op) || !valid_fields(&c.name, &c.email, &c.notes) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid customer"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    authorized(&tx, &who)?;
    let payload = serde_json::to_string(&c).unwrap();

    if replay(&tx, &c.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM customers WHERE id=?1)",
            [&c.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "customer id exists"));
    }
    tx.execute(
        "INSERT INTO customers VALUES (?1,?2,?3,?4,1,?5)",
        params![c.id, c.name, c.email, c.notes, who],
    )
    .map_err(db_error)?;
    audit(&tx, &c.op, &payload, &who, &c.id, "created")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}
#[derive(Deserialize, Serialize)]
pub struct Update {
    name: String,
    email: String,
    notes: String,
    expected_version: i64,
    op: String,
}
pub async fn update(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(c): Json<Update>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&c.op) || !valid_fields(&c.name, &c.email, &c.notes) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid customer"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    authorized(&tx, &who)?;
    let payload = format!("{}:{}", id, serde_json::to_string(&c).unwrap());

    if replay(&tx, &c.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let version: Option<i64> = tx
        .query_row("SELECT version FROM customers WHERE id=?1", [&id], |r| {
            r.get(0)
        })
        .optional()
        .map_err(db_error)?;
    if version.ok_or(err(StatusCode::NOT_FOUND, "customer not found"))? != c.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale customer version"));
    }
    tx.execute(
        "UPDATE customers SET name=?1,email=?2,notes=?3,version=version+1 WHERE id=?4",
        params![c.name, c.email, c.notes, id],
    )
    .map_err(db_error)?;
    audit(&tx, &c.op, &payload, &who, &id, "updated")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::OK)
}
