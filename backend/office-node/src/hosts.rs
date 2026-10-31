//! Experimental opt-in host claims and reports. No process execution lives here.
use super::{db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};

const MAX_LEASE_SECONDS: i64 = 30;
pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS host_credentials(id TEXT PRIMARY KEY, token_hash BLOB NOT NULL UNIQUE, sponsor TEXT NOT NULL REFERENCES actors(id), agent TEXT NOT NULL REFERENCES actors(id), enabled INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS host_claims(job TEXT PRIMARY KEY REFERENCES agent_jobs(id), host TEXT NOT NULL REFERENCES host_credentials(id), fence TEXT NOT NULL, deadline INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS host_reports(job TEXT PRIMARY KEY REFERENCES agent_jobs(id), host TEXT NOT NULL REFERENCES host_credentials(id), op TEXT NOT NULL UNIQUE, digest BLOB NOT NULL, outcome TEXT NOT NULL, summary TEXT NOT NULL, created INTEGER NOT NULL); INSERT OR IGNORE INTO metadata(key,value) VALUES ('host-claims-enabled-v1','false');")
}
fn valid_id(s: &str) -> bool {
    (16..=80).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
struct Host {
    id: String,
    sponsor: String,
    agent: String,
}
fn host(db: &Connection, headers: &HeaderMap) -> Result<Host, ApiError> {
    let token = headers
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or(err(StatusCode::UNAUTHORIZED, "host credential required"))?;
    db.query_row(
        "SELECT id,sponsor,agent FROM host_credentials WHERE token_hash=?1 AND enabled=1",
        [hash(token)],
        |r| {
            Ok(Host {
                id: r.get(0)?,
                sponsor: r.get(1)?,
                agent: r.get(2)?,
            })
        },
    )
    .optional()
    .map_err(db_error)?
    .ok_or(err(StatusCode::UNAUTHORIZED, "invalid host credential"))
}
fn claims_enabled(db: &Connection) -> Result<bool, ApiError> {
    let v: String = db
        .query_row(
            "SELECT value FROM metadata WHERE key='host-claims-enabled-v1'",
            [],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    Ok(v == "true")
}
fn task_allowed(db: &Connection, sponsor: &str, task: &Option<String>) -> Result<bool, ApiError> {
    match task {
        Some(t) => super::tasks::can_edit_task(db, sponsor, t),
        None => Ok(true),
    }
}
fn job_audit(tx: &Transaction<'_>, sponsor: &str, id: &str, action: &str) -> Result<(), ApiError> {
    tx.execute("INSERT INTO agent_job_audit(op,request_hash,actor,job,action,created) VALUES (?1,?2,?3,?4,?5,?6)",params![uuid::Uuid::new_v4().to_string(),hash(action),sponsor,id,action,now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct WaitingJob {
    id: String,
    agent: String,
    task: Option<String>,
    budget: i64,
}
pub async fn jobs(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<WaitingJob>>, ApiError> {
    let db = state.lock().unwrap();
    let h = host(&db, &headers)?;
    if !claims_enabled(&db)? {
        return Err(err(StatusCode::FORBIDDEN, "host claims disabled"));
    }
    let mut stmt=db.prepare("SELECT id,agent,task,budget FROM agent_jobs WHERE state='approved_waiting' AND agent=?1 ORDER BY created,id").map_err(db_error)?;
    let rows = stmt
        .query_map([&h.agent], |r| {
            Ok(WaitingJob {
                id: r.get(0)?,
                agent: r.get(1)?,
                task: r.get(2)?,
                budget: r.get(3)?,
            })
        })
        .map_err(db_error)?;
    let mut result = Vec::new();
    for row in rows {
        let j = row.map_err(db_error)?;
        if task_allowed(&db, &h.sponsor, &j.task)? {
            result.push(j);
            if result.len() == 200 {
                break;
            }
        }
    }
    Ok(Json(result))
}
#[derive(Deserialize)]
pub struct ClaimInput {
    job: String,
}
#[derive(Serialize)]
pub struct Lease {
    job: String,
    fence: String,
    deadline: i64,
    instruction: String,
    agent: String,
    task: Option<String>,
}
pub async fn claim(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(input): Json<ClaimInput>,
) -> Result<Json<Lease>, ApiError> {
    if !valid_id(&input.job) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid job"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let h = host(&tx, &headers)?;
    if !claims_enabled(&tx)? {
        return Err(err(StatusCode::FORBIDDEN, "host claims disabled"));
    }
    let row: Option<(String, Option<String>, String, String)> = tx
        .query_row(
            "SELECT agent,task,instruction,state FROM agent_jobs WHERE id=?1",
            [&input.job],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (agent, task, instruction, status) =
        row.ok_or(err(StatusCode::NOT_FOUND, "job not found"))?;
    if agent != h.agent || !task_allowed(&tx, &h.sponsor, &task)? {
        return Err(err(StatusCode::NOT_FOUND, "job not found"));
    }
    let existing: Option<(String, String, i64)> = tx
        .query_row(
            "SELECT host,fence,deadline FROM host_claims WHERE job=?1",
            [&input.job],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(db_error)?;
    if status == "host_claimed" {
        let (owner, fence, deadline) =
            existing.ok_or(err(StatusCode::INTERNAL_SERVER_ERROR, "claim missing"))?;
        if owner != h.id || deadline <= now() {
            return Err(err(StatusCode::CONFLICT, "claim unavailable"));
        }
        return Ok(Json(Lease {
            job: input.job,
            fence,
            deadline,
            instruction,
            agent,
            task,
        }));
    }
    if status != "approved_waiting" || existing.is_some() {
        return Err(err(StatusCode::CONFLICT, "job not claimable"));
    }
    let fence = uuid::Uuid::new_v4().to_string();
    let deadline = now() + MAX_LEASE_SECONDS;
    tx.execute(
        "INSERT INTO host_claims(job,host,fence,deadline) VALUES (?1,?2,?3,?4)",
        params![input.job, h.id, fence, deadline],
    )
    .map_err(db_error)?;
    tx.execute(
        "UPDATE agent_jobs SET state='host_claimed',version=version+1 WHERE id=?1",
        [&input.job],
    )
    .map_err(db_error)?;
    job_audit(&tx, &h.sponsor, &input.job, &format!("host_claim:{}", h.id))?;
    tx.commit().map_err(db_error)?;
    Ok(Json(Lease {
        job: input.job,
        fence,
        deadline,
        instruction,
        agent,
        task,
    }))
}
#[derive(Serialize)]
pub struct Control {
    active: bool,
    deadline: i64,
}
pub async fn control(
    State(state): State<Db>,
    Path(job): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Control>, ApiError> {
    let db = state.lock().unwrap();
    let h = host(&db, &headers)?;
    let row:Option<(String,i64,String,Option<String>,String)>=db.query_row("SELECT c.host,c.deadline,j.state,j.task,j.agent FROM host_claims c JOIN agent_jobs j ON j.id=c.job WHERE c.job=?1",[&job],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional().map_err(db_error)?;
    let (owner, deadline, status, task, agent) =
        row.ok_or(err(StatusCode::NOT_FOUND, "claim not found"))?;
    if owner != h.id || agent != h.agent {
        return Err(err(StatusCode::NOT_FOUND, "claim not found"));
    }
    let active = status == "host_claimed"
        && deadline > now()
        && claims_enabled(&db)?
        && task_allowed(&db, &h.sponsor, &task)?;
    Ok(Json(Control { active, deadline }))
}
#[derive(Deserialize, Serialize)]
pub struct Report {
    fence: String,
    outcome: String,
    summary: String,
    op: String,
}
pub async fn report(
    State(state): State<Db>,
    Path(job): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Report>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.op)
        || !valid_id(&input.fence)
        || !matches!(input.outcome.as_str(), "success" | "failure")
        || input.summary.trim().is_empty()
        || input.summary.len() > 4000
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid report"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let h = host(&tx, &headers)?;
    if !claims_enabled(&tx)? {
        return Err(err(StatusCode::FORBIDDEN, "host claims disabled"));
    }
    let row:Option<(String,String,i64,String,Option<String>,String)>=tx.query_row("SELECT c.host,c.fence,c.deadline,j.state,j.task,j.agent FROM host_claims c JOIN agent_jobs j ON j.id=c.job WHERE c.job=?1",[&job],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))).optional().map_err(db_error)?;
    let (owner, fence, deadline, status, task, agent) =
        row.ok_or(err(StatusCode::NOT_FOUND, "claim not found"))?;
    if owner != h.id || agent != h.agent || !task_allowed(&tx, &h.sponsor, &task)? {
        return Err(err(StatusCode::NOT_FOUND, "claim not found"));
    }
    if fence != input.fence {
        return Err(err(StatusCode::CONFLICT, "stale fence"));
    }
    let payload = format!("report:{}:{}", job, serde_json::to_string(&input).unwrap());
    let prior: Option<(String, Vec<u8>, String)> = tx
        .query_row(
            "SELECT host,digest,job FROM host_reports WHERE op=?1",
            [&input.op],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(db_error)?;
    if let Some((owner, digest, prior_job)) = prior {
        if owner == h.id && digest == hash(&payload) && prior_job == job {
            return Ok(StatusCode::OK);
        }
        return Err(err(StatusCode::CONFLICT, "operation id conflict"));
    }
    if status != "host_claimed" || deadline <= now() {
        return Err(err(StatusCode::CONFLICT, "claim expired or cancelled"));
    }
    tx.execute("INSERT INTO host_reports(job,host,op,digest,outcome,summary,created) VALUES (?1,?2,?3,?4,?5,?6,?7)",params![job,h.id,input.op,hash(&payload),input.outcome,input.summary,now()]).map_err(db_error)?;
    tx.execute(
        "UPDATE agent_jobs SET state='host_reported',version=version+1 WHERE id=?1",
        [&job],
    )
    .map_err(db_error)?;
    job_audit(
        &tx,
        &h.sponsor,
        &job,
        &format!("host_report:{}:{}", h.id, input.outcome),
    )?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::OK)
}
