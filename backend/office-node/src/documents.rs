//! Server-readable documents, authorized against the current room membership.
use super::{actor, db_error, err, hash, now, permitted, ApiError, Db};
use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};

pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS documents(id TEXT PRIMARY KEY, scope TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, version INTEGER NOT NULL, created_by TEXT NOT NULL REFERENCES actors(id)); CREATE TABLE IF NOT EXISTS document_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL UNIQUE, request_hash BLOB NOT NULL, actor TEXT NOT NULL REFERENCES actors(id), document TEXT NOT NULL REFERENCES documents(id), action TEXT NOT NULL, created INTEGER NOT NULL);")
}
fn valid_id(id: &str) -> bool {
    id.len() >= 16
        && id.len() <= 80
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

pub(super) fn scope_allowed(
    db: &rusqlite::Connection,
    who: &str,
    scope: &str,
) -> Result<bool, ApiError> {
    if scope == "workspace" {
        return Ok(true);
    }
    if let Some(room) = scope.strip_prefix("room:") {
        return permitted(db, who, room);
    }
    Ok(false)
}
fn replay(tx: &Transaction<'_>, op: &str, payload: &str, who: &str) -> Result<bool, ApiError> {
    let prior: Option<(Vec<u8>, String)> = tx
        .query_row(
            "SELECT request_hash,actor FROM document_audit WHERE op=?1",
            [op],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(db_error)?;
    match prior {
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
    tx.execute("INSERT INTO document_audit(op,request_hash,actor,document,action,created) VALUES (?1,?2,?3,?4,?5,?6)",params![op,hash(payload),who,id,action,now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct Document {
    id: String,
    scope: String,
    title: String,
    body: String,
    version: i64,
    created_by: String,
}
#[derive(Deserialize)]
pub struct Search {
    q: Option<String>,
}
pub async fn list(
    State(state): State<Db>,
    Query(search): Query<Search>,
    headers: HeaderMap,
) -> Result<Json<Vec<Document>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    let query = search.q.unwrap_or_default().to_lowercase();
    if query.len() > 200 {
        return Err(err(StatusCode::BAD_REQUEST, "query too long"));
    }
    let mut stmt = db
        .prepare("SELECT id,scope,title,body,version,created_by FROM documents ORDER BY rowid DESC")
        .map_err(db_error)?;
    let rows = stmt
        .query_map([], |r| {
            Ok(Document {
                id: r.get(0)?,
                scope: r.get(1)?,
                title: r.get(2)?,
                body: r.get(3)?,
                version: r.get(4)?,
                created_by: r.get(5)?,
            })
        })
        .map_err(db_error)?;
    let mut result = Vec::new();
    for row in rows {
        let d = row.map_err(db_error)?;
        if scope_allowed(&db, &who, &d.scope)?
            && (query.is_empty()
                || d.title.to_lowercase().contains(&query)
                || d.body.to_lowercase().contains(&query))
        {
            result.push(d);
            if result.len() >= 200 {
                break;
            }
        }
    }
    Ok(Json(result))
}
pub async fn read(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Document>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    let d: Option<Document> = db
        .query_row(
            "SELECT id,scope,title,body,version,created_by FROM documents WHERE id=?1",
            [id],
            |r| {
                Ok(Document {
                    id: r.get(0)?,
                    scope: r.get(1)?,
                    title: r.get(2)?,
                    body: r.get(3)?,
                    version: r.get(4)?,
                    created_by: r.get(5)?,
                })
            },
        )
        .optional()
        .map_err(db_error)?;
    let d = d.ok_or(err(StatusCode::NOT_FOUND, "document not found"))?;
    if !scope_allowed(&db, &who, &d.scope)? {
        return Err(err(StatusCode::NOT_FOUND, "document not found"));
    }
    Ok(Json(d))
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
        .query_row("SELECT scope FROM documents WHERE id=?1", [&id], |r| {
            r.get(0)
        })
        .optional()
        .map_err(db_error)?;
    let scope = scope.ok_or(err(StatusCode::NOT_FOUND, "document not found"))?;
    if !scope_allowed(&db, &who, &scope)? {
        return Err(err(StatusCode::NOT_FOUND, "document not found"));
    }
    let mut stmt = db
        .prepare("SELECT actor,action,created FROM document_audit WHERE document=?1 ORDER BY seq")
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
pub struct NewDocument {
    id: String,
    scope: String,
    title: String,
    body: String,
    op: String,
}
pub async fn create(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(d): Json<NewDocument>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&d.id)
        || !valid_id(&d.op)
        || !monastack_core::documents::valid_content(&d.title, &d.body)
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid document"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    if !scope_allowed(&tx, &who, &d.scope)? {
        return Err(err(StatusCode::FORBIDDEN, "scope access denied"));
    }
    let payload = serde_json::to_string(&d).unwrap();

    if replay(&tx, &d.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM documents WHERE id=?1)",
            [&d.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "document id exists"));
    }
    tx.execute(
        "INSERT INTO documents VALUES (?1,?2,?3,?4,1,?5)",
        params![d.id, d.scope, d.title, d.body, who],
    )
    .map_err(db_error)?;
    audit(&tx, &d.op, &payload, &who, &d.id, "created")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}
#[derive(Deserialize, Serialize)]
pub struct Update {
    title: String,
    body: String,
    expected_version: i64,
    op: String,
}
pub async fn update(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(d): Json<Update>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&d.op) || !monastack_core::documents::valid_content(&d.title, &d.body) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid document"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let row: Option<(String, i64)> = tx
        .query_row(
            "SELECT scope,version FROM documents WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (scope, version) = row.ok_or(err(StatusCode::NOT_FOUND, "document not found"))?;
    if !scope_allowed(&tx, &who, &scope)? {
        return Err(err(StatusCode::NOT_FOUND, "document not found"));
    }
    let payload = format!("{}:{}", id, serde_json::to_string(&d).unwrap());

    if replay(&tx, &d.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    if version != d.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale document version"));
    }
    tx.execute(
        "UPDATE documents SET title=?1,body=?2,version=version+1 WHERE id=?3",
        params![d.title, d.body, id],
    )
    .map_err(db_error)?;
    audit(&tx, &d.op, &payload, &who, &id, "updated")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::OK)
}
