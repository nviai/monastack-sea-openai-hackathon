//! Authenticated, audited restricted-room membership administration on the local node.
use super::{actor, db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};

pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS room_membership_ops(seq INTEGER PRIMARY KEY AUTOINCREMENT,op TEXT NOT NULL UNIQUE,request_hash BLOB NOT NULL,actor TEXT NOT NULL REFERENCES actors(id),room TEXT NOT NULL REFERENCES rooms(id),subject TEXT NOT NULL REFERENCES actors(id),action TEXT NOT NULL,created INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS room_membership_versions(room TEXT PRIMARY KEY REFERENCES rooms(id),version INTEGER NOT NULL);")
}

pub fn membership_version(db: &Connection, room: &str) -> rusqlite::Result<i64> {
    db.query_row(
        "SELECT COALESCE((SELECT version FROM room_membership_versions WHERE room=?1),0)",
        [room],
        |r| r.get(0),
    )
}
pub fn advance_version(tx: &Transaction<'_>, room: &str, current: i64) -> rusqlite::Result<()> {
    tx.execute("INSERT INTO room_membership_versions(room,version) VALUES (?1,?2) ON CONFLICT(room) DO UPDATE SET version=excluded.version", params![room,current + 1])?;
    Ok(())
}

fn is_admin(db: &Connection, who: &str) -> Result<bool, ApiError> {
    let mut stmt = db
        .prepare("SELECT role FROM actor_roles WHERE actor=?1")
        .map_err(db_error)?;
    let roles = stmt
        .query_map([who], |r| r.get::<_, String>(0))
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    Ok(monastack_core::access::can_manage_room_members(&roles))
}
fn restricted_room(db: &Connection, room: &str) -> Result<(), ApiError> {
    let exists: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM rooms WHERE id=?1 AND restricted=1)",
            [room],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !exists {
        return Err(err(StatusCode::NOT_FOUND, "restricted room not found"));
    }
    Ok(())
}

pub async fn capabilities(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiError> {
    let mut db = state.lock().unwrap();
    let tx = db.transaction().map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let can_manage = is_admin(&tx, &who)?;
    tx.commit().map_err(db_error)?;
    Ok(Json(serde_json::json!({"can_manage":can_manage})))
}

#[derive(Serialize)]
pub struct Members {
    members: Vec<String>,
    version: i64,
}
pub async fn members(
    State(state): State<Db>,
    Path(room): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Members>, ApiError> {
    let mut db = state.lock().unwrap();
    let tx = db.transaction().map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    if !is_admin(&tx, &who)? {
        return Err(err(StatusCode::FORBIDDEN, "room administration denied"));
    }
    restricted_room(&tx, &room)?;
    let mut stmt = tx
        .prepare("SELECT actor FROM room_members WHERE room=?1 ORDER BY actor")
        .map_err(db_error)?;
    let members = stmt
        .query_map([&room], |r| r.get::<_, String>(0))
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    drop(stmt);
    let version = membership_version(&tx, &room).map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    Ok(Json(Members { members, version }))
}

#[derive(Deserialize, Serialize)]
pub struct Change {
    actor: String,
    action: String,
    op: String,
    expected_version: i64,
}
pub async fn change(
    State(state): State<Db>,
    Path(room): Path<String>,
    headers: HeaderMap,
    Json(change): Json<Change>,
) -> Result<StatusCode, ApiError> {
    if !matches!(change.action.as_str(), "grant" | "revoke")
        || change.expected_version < 0
        || !(16..=80).contains(&change.op.len())
        || !change
            .op
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid membership operation"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    if !is_admin(&tx, &who)? {
        return Err(err(StatusCode::FORBIDDEN, "room administration denied"));
    }
    restricted_room(&tx, &room)?;
    let human: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1 AND kind='human')",
            [&change.actor],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !human {
        return Err(err(StatusCode::NOT_FOUND, "human not found"));
    }
    let payload = format!("{}:{}", room, serde_json::to_string(&change).unwrap());
    let old: Option<(Vec<u8>, String)> = tx
        .query_row(
            "SELECT request_hash,actor FROM room_membership_ops WHERE op=?1",
            [&change.op],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(db_error)?;
    if let Some((digest, owner)) = old {
        return if digest == hash(&payload) && owner == who {
            Ok(StatusCode::OK)
        } else {
            Err(err(StatusCode::CONFLICT, "operation id conflict"))
        };
    }
    let version = membership_version(&tx, &room).map_err(db_error)?;
    if version != change.expected_version || version == i64::MAX {
        return Err(err(StatusCode::CONFLICT, "stale membership version"));
    }
    let changed = if change.action == "grant" {
        tx.execute(
            "INSERT OR IGNORE INTO room_members(room,actor) VALUES (?1,?2)",
            params![room, change.actor],
        )
    } else {
        tx.execute(
            "DELETE FROM room_members WHERE room=?1 AND actor=?2",
            params![room, change.actor],
        )
    }
    .map_err(db_error)?;
    if changed != 1 {
        return Err(err(
            StatusCode::CONFLICT,
            "membership already has requested state",
        ));
    }
    advance_version(&tx, &room, version).map_err(db_error)?;
    tx.execute("INSERT INTO room_membership_ops(op,request_hash,actor,room,subject,action,created) VALUES (?1,?2,?3,?4,?5,?6,?7)", params![change.op,hash(&payload),who,room,change.actor,change.action,now()]).map_err(db_error)?;
    tx.execute(
        "INSERT INTO security_audit(actor,subject,action,created) VALUES (?1,?2,?3,?4)",
        params![
            who,
            change.actor,
            format!("room_{}:{}", change.action, room),
            now()
        ],
    )
    .map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::OK)
}

#[derive(Serialize)]
pub struct Event {
    actor: String,
    subject: String,
    action: String,
    created: i64,
}
pub async fn history(
    State(state): State<Db>,
    Path(room): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Vec<Event>>, ApiError> {
    let mut db = state.lock().unwrap();
    let tx = db.transaction().map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    if !is_admin(&tx, &who)? {
        return Err(err(StatusCode::FORBIDDEN, "room administration denied"));
    }
    restricted_room(&tx, &room)?;
    let grant = format!("room_grant:{room}");
    let revoke = format!("room_revoke:{room}");
    let mut stmt = tx.prepare("SELECT actor,subject,CASE WHEN action=?1 THEN 'grant' ELSE 'revoke' END,created FROM security_audit WHERE action IN (?1,?2) ORDER BY seq DESC LIMIT 200").map_err(db_error)?;
    let events = stmt
        .query_map(params![grant, revoke], |r| {
            Ok(Event {
                actor: r.get(0)?,
                subject: r.get(1)?,
                action: r.get(2)?,
                created: r.get(3)?,
            })
        })
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    drop(stmt);
    tx.commit().map_err(db_error)?;
    Ok(Json(events))
}
