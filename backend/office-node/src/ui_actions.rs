//! Ephemeral UI capabilities bound to an authenticated app and presence session.
use super::{actor, db_error, err, now, ApiError, Db};
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::Deserialize;
use serde_json::{json, Value};
pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS ui_sessions(session TEXT PRIMARY KEY,actor TEXT NOT NULL,token BLOB NOT NULL,controls TEXT NOT NULL,updated INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS ui_commands(id TEXT PRIMARY KEY,session TEXT NOT NULL,actor TEXT NOT NULL,payload TEXT NOT NULL,state TEXT NOT NULL,result TEXT,created INTEGER NOT NULL);")
}
#[derive(Deserialize)]
pub struct Sync {
    session: String,
    controls: Vec<Value>,
    #[serde(default)]
    results: Vec<Value>,
}
pub async fn sync(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(input): Json<Sync>,
) -> Result<Json<Value>, ApiError> {
    if input.session.len() > 80
        || input.session.len() < 16
        || input.controls.len() > 150
        || input.results.len() > 10
        || serde_json::to_string(&input.controls)
            .unwrap_or_default()
            .len()
            > 64000
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid UI snapshot"));
    }
    let mut db = state.lock().unwrap();
    let tx = db.transaction().map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let token = super::hash(
        headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .unwrap_or(""),
    );
    let existing: Option<(String, Vec<u8>)> = tx
        .query_row(
            "SELECT actor,token FROM ui_sessions WHERE session=?1",
            [&input.session],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(db_error)?;
    if existing.is_some_and(|(owner, _)| owner != who) {
        return Err(err(
            StatusCode::CONFLICT,
            "UI session belongs to another login",
        ));
    }
    tx.execute("INSERT INTO ui_sessions VALUES (?1,?2,?3,?4,?5) ON CONFLICT(session) DO UPDATE SET token=excluded.token,controls=excluded.controls,updated=excluded.updated",params![input.session,who,token,serde_json::to_string(&input.controls).unwrap(),now()]).map_err(db_error)?;
    for result in input.results {
        let id = result["id"].as_str().unwrap_or("");
        let message = result["result"].as_str().unwrap_or("");
        if message.len() > 1000 {
            return Err(err(StatusCode::BAD_REQUEST, "result too long"));
        }
        tx.execute("UPDATE ui_commands SET state='finished',result=?1 WHERE id=?2 AND actor=?3 AND session=?4 AND state='delivered'",params![message,id,who,input.session]).map_err(db_error)?;
    }
    let row:Option<(String,String)>=tx.query_row("SELECT id,payload FROM ui_commands WHERE session=?1 AND actor=?2 AND state='pending' AND created>?3 ORDER BY created LIMIT 1",params![input.session,who,now()-15],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(db_error)?;
    let command = if let Some((id, payload)) = row {
        tx.execute(
            "UPDATE ui_commands SET state='delivered' WHERE id=?1",
            [&id],
        )
        .map_err(db_error)?;
        Some(
            json!({"command_id":id,"action":serde_json::from_str::<Value>(&payload).map_err(|_|err(StatusCode::INTERNAL_SERVER_ERROR,"invalid command"))?}),
        )
    } else {
        None
    };
    tx.execute("DELETE FROM ui_commands WHERE created<?1", [now() - 300])
        .map_err(db_error)?;
    tx.execute("DELETE FROM ui_sessions WHERE updated<?1", [now() - 300])
        .map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    Ok(Json(json!({"command":command})))
}
pub fn controls(db: &Connection, who: &str, session: &str) -> Result<Value, ApiError> {
    let raw: Option<String> = db
        .query_row(
            "SELECT controls FROM ui_sessions WHERE actor=?1 AND session=?2 AND updated>?3",
            params![who, session, now() - 10],
            |r| r.get(0),
        )
        .optional()
        .map_err(db_error)?;
    Ok(raw
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(json!([])))
}
pub fn enqueue(
    db: &Connection,
    who: &str,
    session: &str,
    action: &Value,
) -> Result<String, ApiError> {
    let available = controls(db, who, session)?;
    if !action["id"].is_string()
        || !available
            .as_array()
            .is_some_and(|a| a.iter().any(|c| c["id"] == action["id"]))
        || !action["value"].is_string()
        || action["value"].as_str().unwrap().len() > 16000
    {
        return Err(err(StatusCode::CONFLICT, "control unavailable"));
    }
    let id = uuid::Uuid::new_v4().to_string();
    db.execute(
        "INSERT INTO ui_commands VALUES (?1,?2,?3,?4,'pending',NULL,?5)",
        params![id, session, who, action.to_string(), now()],
    )
    .map_err(db_error)?;
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    fn fixture() -> Db {
        let mut db = Connection::open_in_memory().unwrap();
        crate::initialize(
            &mut db,
            include_str!("../../../data/seed/nviai/seed.v1.json"),
        )
        .unwrap();
        for who in ["an", "van"] {
            db.execute(
                "INSERT INTO tokens VALUES (?1,?2)",
                params![crate::hash(who), who],
            )
            .unwrap();
        }
        Arc::new(Mutex::new(db))
    }
    fn headers(who: &str) -> HeaderMap {
        let mut h = HeaderMap::new();
        h.insert("authorization", format!("Bearer {who}").parse().unwrap());
        h
    }
    fn input() -> Sync {
        Sync {
            session: "ui-session-123456789".into(),
            controls: vec![json!({"id":"open:tasks","label":"Tasks","kind":"navigate"})],
            results: vec![],
        }
    }
    #[tokio::test]
    async fn delivery_is_scoped_and_not_repeated() {
        let db = fixture();
        let _ = sync(State(db.clone()), headers("an"), Json(input()))
            .await
            .unwrap();
        assert_eq!(
            sync(State(db.clone()), headers("van"), Json(input()))
                .await
                .unwrap_err()
                .0,
            StatusCode::CONFLICT
        );
        let id = enqueue(
            &db.lock().unwrap(),
            "an",
            "ui-session-123456789",
            &json!({"id":"open:tasks","value":""}),
        )
        .unwrap();
        let result = sync(State(db.clone()), headers("an"), Json(input()))
            .await
            .unwrap()
            .0;
        assert_eq!(result["command"]["command_id"], id);
        assert!(sync(State(db.clone()), headers("an"), Json(input()))
            .await
            .unwrap()
            .0["command"]
            .is_null());
        let mut ack = input();
        ack.results.push(json!({"id":id,"result":"invoked"}));
        let _ = sync(State(db.clone()), headers("an"), Json(ack))
            .await
            .unwrap();
        assert_eq!(
            db.lock()
                .unwrap()
                .query_row("SELECT state FROM ui_commands WHERE id=?1", [id], |r| {
                    r.get::<_, String>(0)
                })
                .unwrap(),
            "finished"
        );
    }
    #[tokio::test]
    async fn unknown_controls_and_expired_snapshots_are_rejected() {
        let db = fixture();
        let _ = sync(State(db.clone()), headers("an"), Json(input()))
            .await
            .unwrap();
        let guard = db.lock().unwrap();
        assert!(enqueue(
            &guard,
            "van",
            "ui-session-123456789",
            &json!({"id":"open:tasks","value":""})
        )
        .is_err());
        assert!(enqueue(
            &guard,
            "an",
            "ui-session-123456789",
            &json!({"id":"delete-everything","value":""})
        )
        .is_err());
        guard
            .execute("UPDATE ui_sessions SET updated=0", [])
            .unwrap();
        assert!(enqueue(
            &guard,
            "an",
            "ui-session-123456789",
            &json!({"id":"open:tasks","value":""})
        )
        .is_err());
    }
}
