//! Durable task notifications, filtered again against current project access.
use super::{actor, db_error, tasks, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, OptionalExtension, Transaction};
use serde_json::{json, Value};

pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS task_notifications(id INTEGER PRIMARY KEY, recipient TEXT NOT NULL REFERENCES actors(id), task TEXT NOT NULL REFERENCES tasks(id), body TEXT NOT NULL, created INTEGER NOT NULL, read INTEGER NOT NULL DEFAULT 0);")
}
pub async fn list(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<Value>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    let mut stmt = db.prepare("SELECT n.id,n.task,n.body,n.created,n.read,t.title FROM task_notifications n JOIN tasks t ON t.id=n.task WHERE recipient=?1 ORDER BY n.id DESC LIMIT 200").map_err(db_error)?;
    let rows = stmt
        .query_map([&who], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, i64>(3)?,
                r.get::<_, bool>(4)?,
                r.get::<_, String>(5)?,
            ))
        })
        .map_err(db_error)?;
    let mut result = Vec::new();
    for row in rows {
        let (id, task, body, created, read, title) = row.map_err(db_error)?;
        if tasks::can_access_task(&db, &who, &task)? {
            let question: Option<String> = db.query_row("SELECT q.id FROM job_questions q JOIN agent_jobs j ON j.id=q.job WHERE j.task=?1 AND j.created_by=?2 AND q.answer IS NULL AND j.state='waiting_input' ORDER BY q.created DESC LIMIT 1",params![task,who],|r|r.get(0)).optional().map_err(db_error)?;
            let delivery = super::workflow::channel(&db)?;
            result.push(json!({"id":id,"task":task,"body":body,"created":created,"read":read,"title":title,"question":question,"channel":delivery}));
        }
    }
    Ok(Json(result))
}
pub async fn read(
    State(state): State<Db>,
    headers: HeaderMap,
    Path(id): Path<i64>,
) -> Result<StatusCode, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    db.execute(
        "UPDATE task_notifications SET read=1 WHERE id=?1 AND recipient=?2",
        params![id, who],
    )
    .map_err(db_error)?;
    Ok(StatusCode::NO_CONTENT)
}
