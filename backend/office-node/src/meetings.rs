//! Server-readable scoped meeting records. No invitations or audio are sent.
use super::{actor, db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};

pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS meetings(id TEXT PRIMARY KEY, scope TEXT NOT NULL, title TEXT NOT NULL, starts INTEGER NOT NULL, ends INTEGER NOT NULL, creator TEXT NOT NULL REFERENCES actors(id), state TEXT NOT NULL, version INTEGER NOT NULL, created INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS meeting_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL UNIQUE, request_hash BLOB NOT NULL, actor TEXT NOT NULL REFERENCES actors(id), meeting TEXT NOT NULL REFERENCES meetings(id), action TEXT NOT NULL, created INTEGER NOT NULL);")
}
fn valid_id(s: &str) -> bool {
    (16..=80).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn replay(tx: &Transaction<'_>, op: &str, payload: &str, who: &str) -> Result<bool, ApiError> {
    let old: Option<(Vec<u8>, String)> = tx
        .query_row(
            "SELECT request_hash,actor FROM meeting_audit WHERE op=?1",
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
    tx.execute("INSERT INTO meeting_audit(op,request_hash,actor,meeting,action,created) VALUES (?1,?2,?3,?4,?5,?6)",params![op,hash(payload),who,id,action,now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct Meeting {
    id: String,
    scope: String,
    title: String,
    starts: i64,
    ends: i64,
    creator: String,
    state: String,
    version: i64,
}
pub async fn list(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<Meeting>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    let mut stmt=db.prepare("SELECT id,scope,title,starts,ends,creator,state,version FROM meetings ORDER BY starts,id").map_err(db_error)?;
    let rows = stmt
        .query_map([], |r| {
            Ok(Meeting {
                id: r.get(0)?,
                scope: r.get(1)?,
                title: r.get(2)?,
                starts: r.get(3)?,
                ends: r.get(4)?,
                creator: r.get(5)?,
                state: r.get(6)?,
                version: r.get(7)?,
            })
        })
        .map_err(db_error)?;
    let mut result = Vec::new();
    for row in rows {
        let item = row.map_err(db_error)?;
        if super::documents::scope_allowed(&db, &who, &item.scope)? {
            result.push(item);
            if result.len() >= 200 {
                break;
            }
        }
    }
    Ok(Json(result))
}
#[derive(Deserialize, Serialize)]
pub struct NewMeeting {
    id: String,
    scope: String,
    title: String,
    starts: i64,
    ends: i64,
    op: String,
}
pub async fn create(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(input): Json<NewMeeting>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.id)
        || !valid_id(&input.op)
        || !monastack_core::access::valid_meeting(&input.title, input.starts, input.ends)
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid meeting"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    if !super::documents::scope_allowed(&tx, &who, &input.scope)? {
        return Err(err(StatusCode::FORBIDDEN, "scope access denied"));
    }
    let payload = format!("create:{}", serde_json::to_string(&input).unwrap());

    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM meetings WHERE id=?1)",
            [&input.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "meeting id exists"));
    }
    tx.execute(
        "INSERT INTO meetings VALUES (?1,?2,?3,?4,?5,?6,'scheduled',1,?7)",
        params![
            input.id,
            input.scope,
            input.title,
            input.starts,
            input.ends,
            who,
            now()
        ],
    )
    .map_err(db_error)?;
    audit(&tx, &input.op, &payload, &who, &input.id, "scheduled")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}
#[derive(Deserialize, Serialize)]
pub struct Cancel {
    expected_version: i64,
    op: String,
}
#[derive(Deserialize, Serialize)]
pub struct Reschedule {
    title: String,
    starts: i64,
    ends: i64,
    expected_version: i64,
    op: String,
}
pub async fn reschedule(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Reschedule>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.op)
        || !monastack_core::access::valid_meeting(&input.title, input.starts, input.ends)
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid meeting"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let row: Option<(String, String, String, i64)> = tx
        .query_row(
            "SELECT scope,creator,state,version FROM meetings WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (scope, creator, current, version) =
        row.ok_or(err(StatusCode::NOT_FOUND, "meeting not found"))?;
    if !super::documents::scope_allowed(&tx, &who, &scope)? {
        return Err(err(StatusCode::NOT_FOUND, "meeting not found"));
    }
    if who != creator {
        return Err(err(StatusCode::FORBIDDEN, "only creator may reschedule"));
    }
    let payload = format!(
        "reschedule:{}:{}",
        id,
        serde_json::to_string(&input).unwrap()
    );

    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    if version != input.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale meeting version"));
    }
    if current != "scheduled" {
        return Err(err(StatusCode::CONFLICT, "meeting cancelled"));
    }
    tx.execute(
        "UPDATE meetings SET title=?1,starts=?2,ends=?3,version=version+1 WHERE id=?4",
        params![input.title, input.starts, input.ends, id],
    )
    .map_err(db_error)?;
    audit(&tx, &input.op, &payload, &who, &id, "rescheduled")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::OK)
}
pub async fn cancel(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Cancel>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.op) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid operation"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let row: Option<(String, String, String, i64)> = tx
        .query_row(
            "SELECT scope,creator,state,version FROM meetings WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (scope, creator, current, version) =
        row.ok_or(err(StatusCode::NOT_FOUND, "meeting not found"))?;
    if !super::documents::scope_allowed(&tx, &who, &scope)? {
        return Err(err(StatusCode::NOT_FOUND, "meeting not found"));
    }
    if who != creator {
        return Err(err(StatusCode::FORBIDDEN, "only creator may cancel"));
    }
    let payload = format!("cancel:{}:{}", id, serde_json::to_string(&input).unwrap());

    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    if version != input.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale meeting version"));
    }
    if current != "scheduled" {
        return Err(err(StatusCode::CONFLICT, "meeting already cancelled"));
    }
    tx.execute(
        "UPDATE meetings SET state='cancelled',version=version+1 WHERE id=?1",
        [&id],
    )
    .map_err(db_error)?;
    audit(&tx, &input.op, &payload, &who, &id, "cancelled")?;
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
    let scope: Option<String> = db
        .query_row("SELECT scope FROM meetings WHERE id=?1", [&id], |r| {
            r.get(0)
        })
        .optional()
        .map_err(db_error)?;
    let scope = scope.ok_or(err(StatusCode::NOT_FOUND, "meeting not found"))?;
    if !super::documents::scope_allowed(&db, &who, &scope)? {
        return Err(err(StatusCode::NOT_FOUND, "meeting not found"));
    }
    let mut stmt = db
        .prepare("SELECT actor,action,created FROM meeting_audit WHERE meeting=?1 ORDER BY seq")
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
