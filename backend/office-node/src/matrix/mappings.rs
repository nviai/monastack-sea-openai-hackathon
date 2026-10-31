use super::*;

pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS matrix_users(actor TEXT PRIMARY KEY REFERENCES actors(id), user_id TEXT NOT NULL UNIQUE, created INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS matrix_rooms(office_room TEXT PRIMARY KEY REFERENCES rooms(id), room_id TEXT UNIQUE, alias TEXT NOT NULL UNIQUE);
    CREATE TABLE IF NOT EXISTS matrix_dms(member_key TEXT PRIMARY KEY, room_id TEXT UNIQUE, alias TEXT NOT NULL UNIQUE);
    CREATE TABLE IF NOT EXISTS matrix_intents(op TEXT PRIMARY KEY, done INTEGER NOT NULL DEFAULT 0, created INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS matrix_user_config(actor TEXT PRIMARY KEY, name TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS matrix_room_config(room_id TEXT PRIMARY KEY, content TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS matrix_session_revocations(actor TEXT PRIMARY KEY, fingerprint TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS matrix_room_details(office_room TEXT PRIMARY KEY REFERENCES rooms(id), name TEXT NOT NULL, topic TEXT NOT NULL DEFAULT '');")
}

impl Bridge {
    pub(super) fn intent(db: &Db, op: &str) -> Result<(), ApiError> {
        db.lock().unwrap().execute("INSERT INTO matrix_intents(op,created) VALUES (?1,?2) ON CONFLICT(op) DO UPDATE SET done=0,created=excluded.created", params![op,std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos() as i64]).map_err(db_error)?;
        Ok(())
    }
    pub(super) fn done(db: &Db, op: &str) -> Result<(), ApiError> {
        db.lock()
            .unwrap()
            .execute("UPDATE matrix_intents SET done=1 WHERE op=?1", [op])
            .map_err(db_error)?;
        Ok(())
    }
    pub(super) async fn room(
        &self,
        db: &Db,
        key: &str,
        dm: bool,
        name: &str,
        topic: &str,
        restricted: bool,
    ) -> Result<String, ApiError> {
        let _guard = self.resource_gate(format!("room:{dm}:{key}")).await;
        let table = if dm { "matrix_dms" } else { "matrix_rooms" };
        let column = if dm { "member_key" } else { "office_room" };
        let (room, alias): (Option<String>, String) = {
            let mut conn = db.lock().unwrap();
            let tx = conn.transaction().map_err(db_error)?;
            tx.execute(
                &format!("INSERT OR IGNORE INTO {table}({column},alias) VALUES (?1,?2)"),
                params![key, format!("m{}", uuid::Uuid::new_v4().simple())],
            )
            .map_err(db_error)?;
            let result = tx
                .query_row(
                    &format!("SELECT room_id,alias FROM {table} WHERE {column}=?1"),
                    [key],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .map_err(db_error)?;
            tx.commit().map_err(db_error)?;
            result
        };
        let op = format!("room:{table}:{key}");
        Self::intent(db, &op)?;
        let room = match room {
            Some(room) => room,
            None => {
                // The reserved alias is an idempotency key across a crash after
                // createRoom but before the SQLite mapping has been persisted.
                let full_alias = format!("#{alias}:{}", self.server_name);
                let path = format!("/_matrix/client/v3/directory/room/{}", segment(&full_alias));
                let response = self
                    .client
                    .get(format!("{}{}", self.admin_url, path))
                    .bearer_auth(&self.admin_token)
                    .send()
                    .await
                    .map_err(|_| unavailable())?;
                let value: Value = if response.status().is_success() {
                    response.json().await.map_err(|_| unavailable())?
                } else if response.status() == StatusCode::NOT_FOUND {
                    self.call(Method::POST, "/_matrix/client/v3/createRoom", json!({
                        "room_alias_name":alias,"name":name,"topic":topic,"visibility":"private",
                        "creation_content":{"m.federate":false},
                        "power_level_content_override":{"users":{self.admin_user.clone():100},"users_default":0,"events_default":0,"state_default":100,"invite":100,"kick":100,"ban":100,"redact":100},
                        "initial_state":[
                            {"type":"m.room.join_rules","state_key":"","content":{"join_rule":"invite"}},
                            {"type":"m.room.history_visibility","state_key":"","content":{"history_visibility":if restricted || dm {"joined"} else {"shared"}}},
                            {"type":"m.room.guest_access","state_key":"","content":{"guest_access":"forbidden"}}
                        ]
                    })).await?
                } else {
                    return Err(unavailable());
                };
                let room = value["room_id"]
                    .as_str()
                    .ok_or_else(unavailable)?
                    .to_owned();
                db.lock()
                    .unwrap()
                    .execute(
                        &format!("UPDATE {table} SET room_id=?1 WHERE {column}=?2"),
                        params![room, key],
                    )
                    .map_err(db_error)?;
                room
            }
        };
        let content = json!([name, topic, restricted, dm]).to_string();
        let applied: Option<String> = db
            .lock()
            .unwrap()
            .query_row(
                "SELECT content FROM matrix_room_config WHERE room_id=?1",
                [&room],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_error)?;
        if applied.as_deref() == Some(&content) {
            Self::done(db, &op)?;
            return Ok(room);
        }
        // State updates are idempotent. Names/topics can change without new rooms.
        for (event, content) in [
            ("m.room.name", json!({"name":name})),
            ("m.room.topic", json!({"topic":topic})),
            ("m.room.join_rules", json!({"join_rule":"invite"})),
            (
                "m.room.history_visibility",
                json!({"history_visibility":if restricted || dm {"joined"} else {"shared"}}),
            ),
        ] {
            self.call(
                Method::PUT,
                &format!("/_matrix/client/v3/rooms/{}/state/{event}/", segment(&room)),
                content,
            )
            .await?;
        }
        db.lock().unwrap().execute("INSERT INTO matrix_room_config VALUES (?1,?2) ON CONFLICT(room_id) DO UPDATE SET content=excluded.content",params![room,content]).map_err(db_error)?;
        Self::done(db, &op)?;
        Ok(room)
    }
}
pub(super) fn rows(conn: &Connection, sql: &str) -> Result<Vec<(String, String)>, ApiError> {
    let mut stmt = conn.prepare(sql).map_err(db_error)?;
    let result = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    Ok(result)
}
pub(super) fn segment(value: &str) -> String {
    value
        .bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}
pub(super) fn member_key(
    who: &str,
    actors: Vec<String>,
) -> Result<(String, Vec<String>), ApiError> {
    if !(1..=8).contains(&actors.len()) {
        return Err(err(
            StatusCode::BAD_REQUEST,
            "choose one to eight other humans",
        ));
    }
    let mut set: BTreeSet<String> = actors.into_iter().collect();
    set.insert(who.into());
    if set.len() < 2 || set.len() > 9 {
        return Err(err(StatusCode::BAD_REQUEST, "invalid DM members"));
    }
    let members: Vec<_> = set.into_iter().collect();
    Ok((serde_json::to_string(&members).unwrap(), members))
}
