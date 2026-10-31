use super::*;

/// Private gateway policy oracle. It uses the same office policy as all node
/// requests, not a separate membership model. The service credential never
/// leaves loopback; the public gateway never forwards /v1 paths.
#[derive(Deserialize)]
pub struct Authorization {
    user_id: String,
}
pub async fn authorize(
    State(db): State<Db>,
    Extension(config): Extension<Config>,
    headers: HeaderMap,
    Json(input): Json<Authorization>,
) -> Result<Json<Value>, ApiError> {
    let bridge = configured(&config)?;
    let supplied = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .ok_or(err(StatusCode::UNAUTHORIZED, "authentication required"))?;
    let mut mac = Hmac::<Sha256>::new_from_slice(bridge.admin_token.as_bytes()).unwrap();
    mac.update(b"gateway");
    let mut candidate = Hmac::<Sha256>::new_from_slice(supplied.as_bytes()).unwrap();
    candidate.update(b"gateway");
    mac.verify_slice(&candidate.finalize().into_bytes())
        .map_err(|_| err(StatusCode::UNAUTHORIZED, "invalid credential"))?;
    let conn = db.lock().unwrap();
    let who: Option<String> = conn
        .query_row(
            "SELECT actor FROM matrix_users WHERE user_id=?1",
            [&input.user_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(db_error)?;
    let mut allowed = Vec::new();
    let mut aliases = Vec::new();
    let mut users = Vec::new();
    let enabled = who.as_ref().is_some_and(|a| human(&conn, a).is_ok());
    if let Some(who) = who.filter(|_| enabled) {
        for (office, room) in rows(
            &conn,
            "SELECT office_room,room_id FROM matrix_rooms WHERE room_id IS NOT NULL",
        )? {
            if permitted(&conn, &who, &office)? {
                allowed.push(room);
            }
        }
        for (key, room) in rows(
            &conn,
            "SELECT member_key,room_id FROM matrix_dms WHERE room_id IS NOT NULL",
        )? {
            let members: Vec<String> = serde_json::from_str(&key).map_err(|_| unavailable())?;
            if members.contains(&who) {
                allowed.push(room);
            }
        }
    }
    if enabled {
        for (room, alias) in rows(&conn, "SELECT room_id,alias FROM matrix_rooms WHERE room_id IS NOT NULL UNION ALL SELECT room_id,alias FROM matrix_dms WHERE room_id IS NOT NULL")? {
            if allowed.contains(&room) { aliases.push(format!("#{alias}:{}",bridge.server_name)); }
        }
        // The DM contract permits any other enabled human. Service accounts,
        // agents and disabled humans are excluded from the Matrix directory.
        for (actor, user) in rows(&conn, "SELECT actor,user_id FROM matrix_users")? {
            if human(&conn, &actor).is_ok() {
                users.push(user);
            }
        }
    }
    Ok(Json(
        json!({"rooms":allowed,"aliases":aliases,"users":users,"enabled":enabled}),
    ))
}
