//! Durable clarification round trips and workspace delivery preferences.
use super::{actor, db_error, err, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS job_questions(id TEXT PRIMARY KEY,job TEXT NOT NULL REFERENCES agent_jobs(id),question TEXT NOT NULL,answer TEXT,created INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS job_attachments(id TEXT PRIMARY KEY,question TEXT NOT NULL REFERENCES job_questions(id),name TEXT NOT NULL,data TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS workflow_settings(id INTEGER PRIMARY KEY CHECK(id=1),channel TEXT NOT NULL);
INSERT OR IGNORE INTO workflow_settings VALUES (1,'notification');")
}
pub fn channel(db: &Connection) -> Result<String, ApiError> {
    db.query_row(
        "SELECT channel FROM workflow_settings WHERE id=1",
        [],
        |r| r.get(0),
    )
    .map_err(db_error)
}
pub async fn settings(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let db = state.lock().unwrap();
    actor(&db, &headers)?;
    Ok(Json(
        json!({"channel":channel(&db)?,"codex_agents":["dev-agent","qa-agent"]}),
    ))
}
#[derive(Deserialize)]
pub struct Settings {
    channel: String,
}
pub async fn configure(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(input): Json<Settings>,
) -> Result<StatusCode, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    let admin: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM actor_roles WHERE actor=?1 AND role='org-admin')",
            [who],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !admin {
        return Err(err(StatusCode::FORBIDDEN, "admin required"));
    }
    if !matches!(input.channel.as_str(), "notification" | "voice") {
        return Err(err(StatusCode::BAD_REQUEST, "invalid channel"));
    }
    db.execute(
        "UPDATE workflow_settings SET channel=?1 WHERE id=1",
        [input.channel],
    )
    .map_err(db_error)?;
    Ok(StatusCode::OK)
}
#[derive(Deserialize, Serialize)]
pub struct Attachment {
    pub name: String,
    pub data: String,
}
#[derive(Deserialize)]
pub struct Answer {
    pub body: String,
    #[serde(default)]
    pub attachments: Vec<Attachment>,
}
pub async fn answer(
    State(state): State<Db>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(input): Json<Answer>,
) -> Result<StatusCode, ApiError> {
    let mut db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    answer_as(&mut db, &who, &id, input)
}
pub fn answer_as(
    db: &mut Connection,
    who: &str,
    id: &str,
    input: Answer,
) -> Result<StatusCode, ApiError> {
    if input.body.trim().is_empty()
        || input.body.len() > 4000
        || input.attachments.len() > 4
        || input.attachments.iter().any(|a| {
            a.name.is_empty()
                || a.name.len() > 200
                || a.name.contains(['/', '\\'])
                || a.data.len() > 350000
        })
    {
        return Err(err(
            StatusCode::BAD_REQUEST,
            "invalid answer or attachments",
        ));
    }
    use base64::Engine;
    for a in &input.attachments {
        if base64::engine::general_purpose::STANDARD
            .decode(&a.data)
            .map(|b| b.len() > 262144)
            .unwrap_or(true)
        {
            return Err(err(
                StatusCode::BAD_REQUEST,
                "attachment must be base64, maximum 256 KiB",
            ));
        }
    }
    let tx = db.transaction().map_err(db_error)?;
    let row:Option<(String,String,Option<String>,Option<String>,String)>=tx.query_row("SELECT j.id,j.created_by,j.task,q.answer,j.state FROM job_questions q JOIN agent_jobs j ON j.id=q.job WHERE q.id=?1",[&id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional().map_err(db_error)?;
    let (job, owner, task, prior, status) =
        row.ok_or(err(StatusCode::NOT_FOUND, "question not found"))?;
    if who != owner {
        return Err(err(StatusCode::FORBIDDEN, "requester required"));
    }
    if let Some(t) = &task {
        if !super::tasks::can_edit_task(&tx, &who, t)? {
            return Err(err(StatusCode::FORBIDDEN, "ticket access revoked"));
        }
    }
    if prior.is_some() || status != "waiting_input" {
        return Err(err(
            StatusCode::CONFLICT,
            "question already answered or job stopped",
        ));
    }
    tx.execute(
        "UPDATE job_questions SET answer=?1 WHERE id=?2",
        params![input.body, id],
    )
    .map_err(db_error)?;
    for a in input.attachments {
        tx.execute(
            "INSERT INTO job_attachments VALUES (?1,?2,?3,?4)",
            params![uuid::Uuid::new_v4().to_string(), id, a.name, a.data],
        )
        .map_err(db_error)?;
    }
    tx.execute("DELETE FROM host_claims WHERE job=?1", [&job])
        .map_err(db_error)?;
    tx.execute(
        "UPDATE agent_jobs SET state='approved_waiting',version=version+1 WHERE id=?1",
        [&job],
    )
    .map_err(db_error)?;
    if let Some(task) = task {
        tx.execute(
            "INSERT INTO task_comments VALUES (?1,?2,?3,?4,?5)",
            params![
                uuid::Uuid::new_v4().to_string(),
                task,
                who,
                input.body,
                now()
            ],
        )
        .map_err(db_error)?;
    }
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::OK)
}
pub fn context(db: &Connection, job: &str) -> Result<Value, ApiError> {
    let mut q = db
        .prepare("SELECT id,question,answer FROM job_questions WHERE job=?1 ORDER BY created,rowid")
        .map_err(db_error)?;
    let rows=q.query_map([job],|r|Ok(json!({"id":r.get::<_,String>(0)?,"question":r.get::<_,String>(1)?,"answer":r.get::<_,Option<String>>(2)?}))).map_err(db_error)?.collect::<Result<Vec<_>,_>>().map_err(db_error)?;
    let mut attachments=db.prepare("SELECT a.id,a.name,a.data FROM job_attachments a JOIN job_questions q ON q.id=a.question WHERE q.job=?1").map_err(db_error)?;
    let files=attachments.query_map([job],|r|Ok(json!({"id":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"data":r.get::<_,String>(2)?}))).map_err(db_error)?.collect::<Result<Vec<_>,_>>().map_err(db_error)?;
    Ok(json!({"questions":rows,"attachments":files}))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> Connection {
        let mut db = Connection::open_in_memory().unwrap();
        db.execute_batch("PRAGMA foreign_keys=ON").unwrap();
        crate::initialize(
            &mut db,
            include_str!("../../../data/seed/nviai/seed.v1.json"),
        )
        .unwrap();
        db.execute_batch(
            "INSERT INTO projects VALUES ('p','Work','an');
        INSERT INTO tasks VALUES ('t','p','Task','dev-agent','in_progress',1,'an');
        INSERT INTO agent_jobs VALUES ('j','an','dev-agent','t','Work',5,'waiting_input',1,1);
        INSERT INTO job_questions VALUES ('q','j','Which input?',NULL,1);",
        )
        .unwrap();
        db
    }
    #[test]
    fn answer_resumes_with_attachment_and_replay_does_not_duplicate() {
        let mut db = fixture();
        let input = || Answer {
            body: "Use sample".into(),
            attachments: vec![Attachment {
                name: "sample.txt".into(),
                data: "aGVsbG8=".into(),
            }],
        };
        answer_as(&mut db, "an", "q", input()).unwrap();
        assert_eq!(
            db.query_row("SELECT state FROM agent_jobs WHERE id='j'", [], |r| r
                .get::<_, String>(0))
                .unwrap(),
            "approved_waiting"
        );
        let ctx = context(&db, "j").unwrap();
        assert_eq!(ctx["questions"][0]["answer"], "Use sample");
        assert_eq!(ctx["attachments"][0]["data"], "aGVsbG8=");
        assert_eq!(
            answer_as(&mut db, "an", "q", input()).unwrap_err().0,
            StatusCode::CONFLICT
        );
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM task_comments", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            1
        );
    }
    #[test]
    fn wrong_owner_invalid_file_and_cancelled_job_are_rejected() {
        let mut db = fixture();
        let input = || Answer {
            body: "Answer".into(),
            attachments: vec![],
        };
        assert_eq!(
            answer_as(&mut db, "van", "q", input()).unwrap_err().0,
            StatusCode::FORBIDDEN
        );
        let bad = Answer {
            body: "Answer".into(),
            attachments: vec![Attachment {
                name: "../secret".into(),
                data: "aA==".into(),
            }],
        };
        assert_eq!(
            answer_as(&mut db, "an", "q", bad).unwrap_err().0,
            StatusCode::BAD_REQUEST
        );
        db.execute("UPDATE agent_jobs SET state='cancelled'", [])
            .unwrap();
        assert_eq!(
            answer_as(&mut db, "an", "q", input()).unwrap_err().0,
            StatusCode::CONFLICT
        );
        assert!(context(&db, "j").unwrap()["questions"][0]["answer"].is_null());
    }
}
