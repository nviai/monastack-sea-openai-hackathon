//! Scope-protected shared notes; deletes are retained as tombstones.
use super::{actor, db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS whiteboard_notes(id TEXT PRIMARY KEY, scope TEXT NOT NULL, text TEXT NOT NULL, x INTEGER NOT NULL, y INTEGER NOT NULL, version INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, created_by TEXT NOT NULL REFERENCES actors(id)); CREATE TABLE IF NOT EXISTS whiteboard_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL UNIQUE, request_hash BLOB NOT NULL, actor TEXT NOT NULL REFERENCES actors(id), note TEXT NOT NULL REFERENCES whiteboard_notes(id), action TEXT NOT NULL, created INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS whiteboard_scope ON whiteboard_notes(scope,deleted);")
}
fn valid_id(s: &str) -> bool {
    (16..=80).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn replay(tx: &Transaction<'_>, op: &str, payload: &str, who: &str) -> Result<bool, ApiError> {
    let old: Option<(Vec<u8>, String)> = tx
        .query_row(
            "SELECT request_hash,actor FROM whiteboard_audit WHERE op=?1",
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
    tx.execute("INSERT INTO whiteboard_audit(op,request_hash,actor,note,action,created) VALUES (?1,?2,?3,?4,?5,?6)",params![op,hash(payload),who,id,action,now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct Note {
    id: String,
    scope: String,
    text: String,
    x: i64,
    y: i64,
    version: i64,
    created_by: String,
}
#[derive(Deserialize)]
pub struct Search {
    scope: String,
}
pub async fn list(
    State(state): State<Db>,
    Query(q): Query<Search>,
    headers: HeaderMap,
) -> Result<Json<Vec<Note>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    if !super::documents::scope_allowed(&db, &who, &q.scope)? {
        return Err(err(StatusCode::FORBIDDEN, "scope access denied"));
    }
    let mut stmt=db.prepare("SELECT id,scope,text,x,y,version,created_by FROM whiteboard_notes WHERE scope=?1 AND deleted=0 ORDER BY rowid DESC LIMIT 200").map_err(db_error)?;
    let rows = stmt
        .query_map([q.scope], |r| {
            Ok(Note {
                id: r.get(0)?,
                scope: r.get(1)?,
                text: r.get(2)?,
                x: r.get(3)?,
                y: r.get(4)?,
                version: r.get(5)?,
                created_by: r.get(6)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
#[derive(Deserialize, Serialize)]
pub struct NewNote {
    id: String,
    scope: String,
    text: String,
    x: i64,
    y: i64,
    op: String,
}
pub async fn create(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(input): Json<NewNote>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.id)
        || !valid_id(&input.op)
        || !monastack_core::access::valid_whiteboard_note(&input.text, input.x, input.y)
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid note"));
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
            "SELECT EXISTS(SELECT 1 FROM whiteboard_notes WHERE id=?1)",
            [&input.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "note id exists"));
    }
    tx.execute(
        "INSERT INTO whiteboard_notes VALUES (?1,?2,?3,?4,?5,1,0,?6)",
        params![input.id, input.scope, input.text, input.x, input.y, who],
    )
    .map_err(db_error)?;
    audit(&tx, &input.op, &payload, &who, &input.id, "created")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}
#[derive(Deserialize, Serialize)]
pub struct Update {
    text: Option<String>,
    x: Option<i64>,
    y: Option<i64>,
    delete: bool,
    expected_version: i64,
    op: String,
}
pub async fn update(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Update>,
) -> Result<StatusCode, ApiError> {
    let valid = if input.delete {
        input.text.is_none() && input.x.is_none() && input.y.is_none()
    } else {
        match (&input.text, input.x, input.y) {
            (Some(text), Some(x), Some(y)) => {
                monastack_core::access::valid_whiteboard_note(text, x, y)
            }
            _ => false,
        }
    };
    if !valid_id(&input.op) || !valid {
        return Err(err(StatusCode::BAD_REQUEST, "invalid note update"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let row: Option<(String, i64, bool)> = tx
        .query_row(
            "SELECT scope,version,deleted FROM whiteboard_notes WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (scope, version, deleted) = row.ok_or(err(StatusCode::NOT_FOUND, "note not found"))?;
    if !super::documents::scope_allowed(&tx, &who, &scope)? {
        return Err(err(StatusCode::NOT_FOUND, "note not found"));
    }
    let payload = format!("update:{}:{}", id, serde_json::to_string(&input).unwrap());

    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    if version != input.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale note version"));
    }
    if deleted {
        return Err(err(StatusCode::CONFLICT, "note deleted"));
    }
    if input.delete {
        tx.execute(
            "UPDATE whiteboard_notes SET deleted=1,version=version+1 WHERE id=?1",
            [&id],
        )
        .map_err(db_error)?;
    } else {
        tx.execute(
            "UPDATE whiteboard_notes SET text=?1,x=?2,y=?3,version=version+1 WHERE id=?4",
            params![input.text, input.x, input.y, id],
        )
        .map_err(db_error)?;
    }
    audit(
        &tx,
        &input.op,
        &payload,
        &who,
        &id,
        if input.delete { "deleted" } else { "updated" },
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
    let scope: Option<String> = db
        .query_row(
            "SELECT scope FROM whiteboard_notes WHERE id=?1",
            [&id],
            |r| r.get(0),
        )
        .optional()
        .map_err(db_error)?;
    let scope = scope.ok_or(err(StatusCode::NOT_FOUND, "note not found"))?;
    if !super::documents::scope_allowed(&db, &who, &scope)? {
        return Err(err(StatusCode::NOT_FOUND, "note not found"));
    }
    let mut stmt = db
        .prepare("SELECT actor,action,created FROM whiteboard_audit WHERE note=?1 ORDER BY seq")
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
