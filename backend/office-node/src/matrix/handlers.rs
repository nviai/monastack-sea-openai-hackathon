use super::*;

pub async fn config(
    State(db): State<Db>,
    Extension(config): Extension<Config>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    {
        let conn = db.lock().unwrap();
        actor(&conn, &headers)?;
    }
    Ok(Json(match config {
        Some(c) => {
            json!({"enabled":true,"homeserver_url":c.public_url,"server_name":c.server_name})
        }
        None => json!({"enabled":false}),
    }))
}
#[derive(Deserialize)]
pub struct Session {
    #[serde(default)]
    device_name: String,
}
pub async fn session(
    State(db): State<Db>,
    Extension(config): Extension<Config>,
    headers: HeaderMap,
    Json(input): Json<Session>,
) -> Result<Json<Value>, ApiError> {
    let who = caller(&db, &headers)?;
    if input.device_name.is_empty() || input.device_name.len() > 200 {
        return Err(err(StatusCode::BAD_REQUEST, "invalid device name"));
    }
    let bridge = configured(&config)?;
    let _guard = bridge.gate.lock().await;
    let user = bridge.user(&db, &who).await?;
    // Recheck the bearer after provisioning, which can take several seconds.
    caller(&db, &headers)?;
    let localpart = user
        .strip_prefix('@')
        .and_then(|s| s.split_once(':'))
        .ok_or_else(unavailable)?
        .0;
    Ok(Json(
        json!({"user_id":user,"login_token":jwt(&bridge.jwt_secret,localpart,now()),"expires_in":60}),
    ))
}
pub async fn users(
    State(db): State<Db>,
    Extension(config): Extension<Config>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    caller(&db, &headers)?;
    let bridge = configured(&config)?;
    let _guard = bridge.gate.lock().await;
    let humans = {
        let conn = db.lock().unwrap();
        rows(&conn,"SELECT a.id,a.name FROM actors a LEFT JOIN accounts c ON c.actor=a.id WHERE a.kind='human' AND COALESCE(c.disabled,0)=0 ORDER BY a.id")?
    };
    let mut result = Vec::new();
    for (who, name) in humans {
        let user = bridge.user(&db, &who).await?;
        result.push(json!({"actor":who,"user_id":user,"name":name,"kind":"human"}));
    }
    Ok(Json(json!(result)))
}
pub async fn rooms(
    State(db): State<Db>,
    Extension(config): Extension<Config>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let who = caller(&db, &headers)?;
    let bridge = configured(&config)?;
    bridge.caller_rooms(&db, &who).await?;
    caller(&db, &headers)?;
    let conn = db.lock().unwrap();
    human(&conn, &who)?;
    let mut stmt=conn.prepare("SELECT r.id,m.room_id,COALESCE(d.name,r.id),COALESCE(d.topic,''),r.restricted FROM rooms r JOIN matrix_rooms m ON m.office_room=r.id LEFT JOIN matrix_room_details d ON d.office_room=r.id").map_err(db_error)?;
    let rows = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, bool>(4)?,
            ))
        })
        .map_err(db_error)?;
    let mut result = Vec::new();
    for row in rows {
        let (id, room, name, topic, restricted) = row.map_err(db_error)?;
        if permitted(&conn, &who, &id)? {
            result.push(json!({"office_room":id,"matrix_room_id":room,"name":name,"topic":topic,"restricted":restricted}));
        }
    }
    Ok(Json(json!(result)))
}
#[derive(Deserialize)]
pub struct Dm {
    actors: Vec<String>,
}
pub async fn dms(
    State(db): State<Db>,
    Extension(config): Extension<Config>,
    headers: HeaderMap,
    Json(input): Json<Dm>,
) -> Result<Json<Value>, ApiError> {
    let who = caller(&db, &headers)?;
    let (key, members) = member_key(&who, input.actors)?;
    {
        let conn = db.lock().unwrap();
        for m in &members {
            human(&conn, m)?;
        }
    }
    let bridge = configured(&config)?;
    let _guard = bridge.gate.lock().await;
    let existing: bool = db
        .lock()
        .unwrap()
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM matrix_dms WHERE member_key=?1 AND room_id IS NOT NULL)",
            [&key],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    let mut desired = BTreeSet::new();
    for m in &members {
        desired.insert(bridge.user(&db, m).await?);
    }
    let room = bridge
        .room(&db, &key, true, "Direct message", "", true)
        .await?;
    bridge.memberships(&db, &room, &desired).await?;
    caller(&db, &headers)?;
    Ok(Json(json!({"matrix_room_id":room,"created":!existing})))
}
pub async fn list_dms(State(db): State<Db>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let conn = db.lock().unwrap();
    let who = actor(&conn, &headers)?;
    human(&conn, &who)?;
    let mut result = Vec::new();
    for (key, room) in rows(
        &conn,
        "SELECT member_key,room_id FROM matrix_dms WHERE room_id IS NOT NULL ORDER BY member_key",
    )? {
        let actors: Vec<String> = serde_json::from_str(&key).unwrap_or_default();
        if actors.contains(&who) {
            result.push(json!({"matrix_room_id":room,"actors":actors}));
        }
    }
    Ok(Json(json!(result)))
}
#[derive(Default, Deserialize)]
pub struct LegacyQuery {
    pub before: Option<i64>,
    pub limit: Option<u32>,
}
pub async fn legacy(
    State(db): State<Db>,
    Path(scope): Path<String>,
    headers: HeaderMap,
    Query(query): Query<LegacyQuery>,
) -> Result<Json<Value>, ApiError> {
    let conn = db.lock().unwrap();
    let who = actor(&conn, &headers)?;
    human(&conn, &who)?;
    let raw = if let Some(members) = scope.strip_prefix("dm:").and_then(|s| s.split_once(':')) {
        let other = if members.0 == who {
            members.1
        } else if members.1 == who {
            members.0
        } else {
            return Err(err(StatusCode::FORBIDDEN, "DM access denied"));
        };
        format!("dm:{other}")
    } else {
        scope
    };
    let scope = crate::scope_for(&conn, &who, &raw)?;
    let mut stmt=conn.prepare("SELECT m.id,m.sender,a.name,m.body,m.created FROM messages m JOIN actors a ON a.id=m.sender WHERE m.scope=?1 AND (?2 IS NULL OR m.created<?2) ORDER BY m.created DESC,m.rowid DESC LIMIT ?3").map_err(db_error)?;
    let rows=stmt.query_map(params![scope,query.before,query.limit.unwrap_or(50).clamp(1,100)],|r|Ok(json!({"id":r.get::<_,String>(0)?,"sender_actor":r.get::<_,String>(1)?,"sender_name":r.get::<_,String>(2)?,"body":r.get::<_,String>(3)?,"created":r.get::<_,i64>(4)?}))).map_err(db_error)?.collect::<Result<Vec<_>,_>>().map_err(db_error)?;
    Ok(Json(json!(rows)))
}
