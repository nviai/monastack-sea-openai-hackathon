//! Proposals are durable records only; there is no worker or execution here.
use super::{actor, db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};

pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS actor_roles(actor TEXT NOT NULL REFERENCES actors(id), role TEXT NOT NULL, PRIMARY KEY(actor,role));
 CREATE TABLE IF NOT EXISTS agent_jobs(id TEXT PRIMARY KEY, created_by TEXT NOT NULL REFERENCES actors(id), agent TEXT NOT NULL REFERENCES actors(id), task TEXT REFERENCES tasks(id), instruction TEXT NOT NULL, budget INTEGER NOT NULL, state TEXT NOT NULL, version INTEGER NOT NULL, created INTEGER NOT NULL);
 CREATE TABLE IF NOT EXISTS agent_job_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL UNIQUE, request_hash BLOB NOT NULL, actor TEXT NOT NULL REFERENCES actors(id), job TEXT NOT NULL REFERENCES agent_jobs(id), action TEXT NOT NULL, created INTEGER NOT NULL);")
}
pub fn seed_roles(
    tx: &Transaction<'_>,
    actors: &[serde_json::Value],
) -> Result<(), Box<dyn std::error::Error>> {
    let applied: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='actor-roles-v1')",
        [],
        |r| r.get(0),
    )?;
    if !applied {
        for a in actors {
            if a["kind"] == "human" && a["role"] == "org-admin" {
                tx.execute(
                    "INSERT OR IGNORE INTO actor_roles VALUES (?1,'org-admin')",
                    [a["id"].as_str().ok_or("missing actor id")?],
                )?;
            }
        }
        tx.execute(
            "INSERT INTO metadata VALUES ('actor-roles-v1','applied')",
            [],
        )?;
    }
    Ok(())
}
fn valid_id(s: &str) -> bool {
    s.len() >= 16
        && s.len() <= 80
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn admin(tx: &Transaction<'_>, who: &str) -> Result<bool, ApiError> {
    tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM actor_roles WHERE actor=?1 AND role='org-admin')",
        [who],
        |r| r.get(0),
    )
    .map_err(db_error)
}
fn replay(tx: &Transaction<'_>, op: &str, payload: &str, who: &str) -> Result<bool, ApiError> {
    let old: Option<(Vec<u8>, String)> = tx
        .query_row(
            "SELECT request_hash,actor FROM agent_job_audit WHERE op=?1",
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
    job: &str,
    action: &str,
) -> Result<(), ApiError> {
    tx.execute("INSERT INTO agent_job_audit(op,request_hash,actor,job,action,created) VALUES (?1,?2,?3,?4,?5,?6)",params![op,hash(payload),who,job,action,now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct Job {
    id: String,
    created_by: String,
    agent: String,
    task: Option<String>,
    instruction: String,
    budget: i64,
    state: String,
    version: i64,
    host: Option<String>,
    report_outcome: Option<String>,
    report_summary: Option<String>,
}
#[derive(Deserialize, Serialize)]
pub struct Proposal {
    id: String,
    agent: String,
    task: Option<String>,
    instruction: String,
    budget: i64,
    op: String,
}
pub async fn list(State(state): State<Db>, headers: HeaderMap) -> Result<Json<Vec<Job>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    let mut stmt=db.prepare("SELECT j.id,j.created_by,j.agent,j.task,j.instruction,j.budget,j.state,j.version,c.host,r.outcome,r.summary FROM agent_jobs j LEFT JOIN host_claims c ON c.job=j.id LEFT JOIN host_reports r ON r.job=j.id ORDER BY j.rowid DESC LIMIT 200").map_err(db_error)?;
    let rows = stmt
        .query_map([], |r| {
            Ok(Job {
                id: r.get(0)?,
                created_by: r.get(1)?,
                agent: r.get(2)?,
                task: r.get(3)?,
                instruction: r.get(4)?,
                budget: r.get(5)?,
                state: r.get(6)?,
                version: r.get(7)?,
                host: r.get(8)?,
                report_outcome: r.get(9)?,
                report_summary: r.get(10)?,
            })
        })
        .map_err(db_error)?;
    let mut jobs = Vec::new();
    for row in rows {
        let job = row.map_err(db_error)?;
        if job
            .task
            .as_ref()
            .map(|t| super::tasks::can_access_task(&db, &who, t))
            .transpose()?
            .unwrap_or(true)
        {
            jobs.push(job);
        }
    }
    Ok(Json(jobs))
}
pub async fn create(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(p): Json<Proposal>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&p.id)
        || !valid_id(&p.op)
        || p.instruction.trim().is_empty()
        || p.instruction.len() > 4000
        || !(1..=100).contains(&p.budget)
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid job proposal"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    if let Some(task) = &p.task {
        if !super::tasks::can_access_task(&tx, &who, task)? {
            return Err(err(StatusCode::NOT_FOUND, "task not found"));
        }
        if !super::tasks::can_edit_task(&tx, &who, task)? {
            return Err(err(StatusCode::FORBIDDEN, "project is read-only"));
        }
    }
    let payload = serde_json::to_string(&p).unwrap();

    if replay(&tx, &p.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let is_agent: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1 AND kind='agent')",
            [&p.agent],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !is_agent {
        return Err(err(StatusCode::BAD_REQUEST, "unknown agent"));
    }
    if let Some(task) = &p.task {
        let exists: bool = tx
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM tasks WHERE id=?1)",
                [task],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        if !exists {
            return Err(err(StatusCode::BAD_REQUEST, "unknown task"));
        }
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM agent_jobs WHERE id=?1)",
            [&p.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "job id exists"));
    }
    tx.execute(
        "INSERT INTO agent_jobs VALUES (?1,?2,?3,?4,?5,?6,'proposed',1,?7)",
        params![p.id, who, p.agent, p.task, p.instruction, p.budget, now()],
    )
    .map_err(db_error)?;
    audit(&tx, &p.op, &payload, &who, &p.id, "proposed")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}
fn require_job_access(db: &rusqlite::Connection, who: &str, id: &str) -> Result<(), ApiError> {
    let task: Option<Option<String>> = db
        .query_row("SELECT task FROM agent_jobs WHERE id=?1", [id], |r| {
            r.get(0)
        })
        .optional()
        .map_err(db_error)?;
    let task = task.ok_or(err(StatusCode::NOT_FOUND, "job not found"))?;
    if let Some(task) = task {
        if !super::tasks::can_access_task(db, who, &task)? {
            return Err(err(StatusCode::NOT_FOUND, "job not found"));
        }
    }
    Ok(())
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
    if !valid_id(&d.op) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid operation"));
    }
    let next = match d.action.as_str() {
        "approve" => monastack_core::jobs::JobState::ApprovedWaiting,
        "cancel" => monastack_core::jobs::JobState::Cancelled,
        _ => return Err(err(StatusCode::BAD_REQUEST, "invalid decision")),
    };
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    require_job_access(&tx, &who, &id)?;
    let task: Option<String> = tx
        .query_row("SELECT task FROM agent_jobs WHERE id=?1", [&id], |r| {
            r.get(0)
        })
        .map_err(db_error)?;
    if let Some(task) = task {
        if !super::tasks::can_edit_task(&tx, &who, &task)? {
            return Err(err(StatusCode::FORBIDDEN, "project is read-only"));
        }
    }
    let payload = format!("{}:{}", id, serde_json::to_string(&d).unwrap());

    let row: Option<(String, String, i64)> = tx
        .query_row(
            "SELECT created_by,state,version FROM agent_jobs WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (owner, state, version) = row.ok_or(err(StatusCode::NOT_FOUND, "job not found"))?;
    let is_admin = admin(&tx, &who)?;
    if (d.action == "approve" && !is_admin) || (d.action == "cancel" && !is_admin && who != owner) {
        return Err(err(StatusCode::FORBIDDEN, "decision not permitted"));
    }
    if replay(&tx, &d.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    if version != d.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale job version"));
    }
    let current = monastack_core::jobs::JobState::parse(&state)
        .ok_or(err(StatusCode::INTERNAL_SERVER_ERROR, "invalid job state"))?;
    if !current.allows(next) {
        return Err(err(StatusCode::CONFLICT, "invalid decision"));
    }
    let new_state = if d.action == "approve" {
        "approved_waiting"
    } else {
        "cancelled"
    };
    tx.execute(
        "UPDATE agent_jobs SET state=?1,version=version+1 WHERE id=?2",
        params![new_state, id],
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
    require_job_access(&db, &who, &id)?;
    let exists: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM agent_jobs WHERE id=?1)",
            [&id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !exists {
        return Err(err(StatusCode::NOT_FOUND, "job not found"));
    }
    let mut stmt = db
        .prepare("SELECT actor,action,created FROM agent_job_audit WHERE job=?1 ORDER BY seq")
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
