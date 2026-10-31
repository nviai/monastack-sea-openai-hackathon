//! Online incident reports. Operations membership is an explicit authority grant.
use super::{actor, db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};

pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS incidents(id TEXT PRIMARY KEY, reporter TEXT NOT NULL REFERENCES actors(id), title TEXT NOT NULL, description TEXT NOT NULL, severity TEXT NOT NULL, state TEXT NOT NULL, version INTEGER NOT NULL, created INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS incident_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL UNIQUE, request_hash BLOB NOT NULL, actor TEXT NOT NULL REFERENCES actors(id), incident TEXT NOT NULL REFERENCES incidents(id), action TEXT NOT NULL, created INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS incident_comments(id TEXT PRIMARY KEY, incident TEXT NOT NULL REFERENCES incidents(id), author TEXT NOT NULL REFERENCES actors(id), body TEXT NOT NULL, created INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS incident_comments_incident ON incident_comments(incident,created);")
}
fn valid_id(s: &str) -> bool {
    (16..=80).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn responder(db: &Connection, who: &str) -> Result<bool, ApiError> {
    let mut statement = db
        .prepare("SELECT role FROM actor_roles WHERE actor=?1")
        .map_err(db_error)?;
    let roles = statement
        .query_map([who], |r| r.get::<_, String>(0))
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    Ok(monastack_core::access::can_manage_incidents(&roles))
}
fn require_access(db: &Connection, who: &str, id: &str) -> Result<(), ApiError> {
    let reporter: Option<String> = db
        .query_row("SELECT reporter FROM incidents WHERE id=?1", [id], |r| {
            r.get(0)
        })
        .optional()
        .map_err(db_error)?;
    match reporter {
        Some(owner) if owner == who || responder(db, who)? => Ok(()),
        _ => Err(err(StatusCode::NOT_FOUND, "incident not found")),
    }
}
fn replay(tx: &Transaction<'_>, op: &str, payload: &str, who: &str) -> Result<bool, ApiError> {
    let old: Option<(Vec<u8>, String)> = tx
        .query_row(
            "SELECT request_hash,actor FROM incident_audit WHERE op=?1",
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
    tx.execute("INSERT INTO incident_audit(op,request_hash,actor,incident,action,created) VALUES (?1,?2,?3,?4,?5,?6)", params![op, hash(payload), who, id, action, now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct Incident {
    id: String,
    reporter: String,
    title: String,
    description: String,
    severity: String,
    state: String,
    version: i64,
}
pub async fn list(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<Incident>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    let is_responder = responder(&db, &who)?;
    let mut stmt = db.prepare("SELECT id,reporter,title,description,severity,state,version FROM incidents WHERE reporter=?1 OR ?2=1 ORDER BY rowid DESC LIMIT 200").map_err(db_error)?;
    let rows = stmt
        .query_map(params![who, is_responder], |r| {
            Ok(Incident {
                id: r.get(0)?,
                reporter: r.get(1)?,
                title: r.get(2)?,
                description: r.get(3)?,
                severity: r.get(4)?,
                state: r.get(5)?,
                version: r.get(6)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
#[derive(Deserialize, Serialize)]
pub struct NewIncident {
    id: String,
    title: String,
    description: String,
    severity: String,
    op: String,
}
pub async fn create(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(input): Json<NewIncident>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.id)
        || !valid_id(&input.op)
        || !monastack_core::access::valid_incident(
            &input.title,
            &input.description,
            &input.severity,
        )
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid incident"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let payload = format!("create:{}", serde_json::to_string(&input).unwrap());

    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM incidents WHERE id=?1)",
            [&input.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "incident id exists"));
    }
    tx.execute(
        "INSERT INTO incidents VALUES (?1,?2,?3,?4,?5,'open',1,?6)",
        params![
            input.id,
            who,
            input.title,
            input.description,
            input.severity,
            now()
        ],
    )
    .map_err(db_error)?;
    audit(&tx, &input.op, &payload, &who, &input.id, "reported")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}
#[derive(Deserialize, Serialize)]
pub struct Transition {
    action: String,
    expected_version: i64,
    op: String,
}
pub async fn transition(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Transition>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.op) || !matches!(input.action.as_str(), "investigate" | "resolve") {
        return Err(err(StatusCode::BAD_REQUEST, "invalid transition"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    if !responder(&tx, &who)? {
        return Err(err(StatusCode::FORBIDDEN, "operations access required"));
    }
    let payload = format!(
        "transition:{}:{}",
        id,
        serde_json::to_string(&input).unwrap()
    );

    let row: Option<(String, String, i64)> = tx
        .query_row(
            "SELECT reporter,state,version FROM incidents WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (reporter, current, version) =
        row.ok_or(err(StatusCode::NOT_FOUND, "incident not found"))?;
    if who == reporter {
        return Err(err(
            StatusCode::FORBIDDEN,
            "reporter cannot resolve own incident",
        ));
    }
    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    if version != input.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale incident version"));
    }
    let next = match (current.as_str(), input.action.as_str()) {
        ("open", "investigate") => "investigating",
        ("investigating", "resolve") => "resolved",
        _ => return Err(err(StatusCode::CONFLICT, "invalid incident transition")),
    };
    tx.execute(
        "UPDATE incidents SET state=?1,version=version+1 WHERE id=?2",
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
    let owner: Option<String> = db
        .query_row("SELECT reporter FROM incidents WHERE id=?1", [&id], |r| {
            r.get(0)
        })
        .optional()
        .map_err(db_error)?;
    let owner = owner.ok_or(err(StatusCode::NOT_FOUND, "incident not found"))?;
    if who != owner && !responder(&db, &who)? {
        return Err(err(StatusCode::NOT_FOUND, "incident not found"));
    }
    let mut stmt = db
        .prepare("SELECT actor,action,created FROM incident_audit WHERE incident=?1 ORDER BY seq")
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

#[derive(Serialize)]
pub struct Comment {
    id: String,
    author: String,
    body: String,
    created: i64,
}

pub async fn comments(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Vec<Comment>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    require_access(&db, &who, &id)?;
    let mut stmt = db.prepare("SELECT id,author,body,created FROM (SELECT rowid,id,author,body,created FROM incident_comments WHERE incident=?1 ORDER BY rowid DESC LIMIT 500) ORDER BY rowid").map_err(db_error)?;
    let rows = stmt
        .query_map([id], |r| {
            Ok(Comment {
                id: r.get(0)?,
                author: r.get(1)?,
                body: r.get(2)?,
                created: r.get(3)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}

#[derive(Deserialize, Serialize)]
pub struct NewComment {
    id: String,
    body: String,
    op: String,
}

pub async fn add_comment(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<NewComment>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.id)
        || !valid_id(&input.op)
        || !monastack_core::access::valid_incident_comment(&input.body)
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid incident comment"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;

    require_access(&tx, &who, &id)?;
    let payload = format!("comment:{}:{}", id, serde_json::to_string(&input).unwrap());
    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM incident_comments WHERE id=?1)",
            [&input.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "comment id exists"));
    }
    tx.execute(
        "INSERT INTO incident_comments(id,incident,author,body,created) VALUES (?1,?2,?3,?4,?5)",
        params![input.id, id, who, input.body, now()],
    )
    .map_err(db_error)?;
    audit(&tx, &input.op, &payload, &who, &id, "commented")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}
