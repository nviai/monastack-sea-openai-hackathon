mod bookings;
mod contracts;
mod customers;
mod documents;
mod expenses;
mod hosts;
mod incidents;
mod jobs;
mod journals;
mod leave;
mod media;
mod meetings;
mod payments;
mod realtime;
mod room_admin;
mod sales;
mod support;
mod tasks;
mod whiteboard;

use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    routing::get,
    Json, Router,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    env,
    io::{self, Read},
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

type Db = Arc<Mutex<Connection>>;
type ApiError = (StatusCode, &'static str);
fn err(code: StatusCode, msg: &'static str) -> ApiError {
    (code, msg)
}
fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}
fn hash(token: &str) -> Vec<u8> {
    Sha256::digest(token.as_bytes()).to_vec()
}
fn db_error(_: rusqlite::Error) -> ApiError {
    err(StatusCode::INTERNAL_SERVER_ERROR, "storage error")
}

fn initialize(db: &mut Connection, seed: &str) -> Result<(), Box<dyn std::error::Error>> {
    let v: serde_json::Value = serde_json::from_str(seed)?;
    if v["version"] != 1 || v["workspace"]["id"] != "nviai" {
        return Err("invalid seed version or workspace".into());
    }
    let actors = v["actors"].as_array().ok_or("missing actors")?;
    let rooms = v["rooms"].as_array().ok_or("missing rooms")?;
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let version: i64 = tx.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if version > 16 {
        return Err("database schema is newer than this node; refusing to modify it".into());
    }
    let has_metadata: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='metadata')",
        [],
        |r| r.get(0),
    )?;
    let tables: i64 = tx.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
        [],
        |r| r.get(0),
    )?;
    if tables > 0 {
        if !has_metadata {
            return Err(
                "database is not an initialized Monastack workspace; refusing to modify it".into(),
            );
        }
        let marker: Option<String> = tx
            .query_row("SELECT value FROM metadata WHERE key='seed-v1'", [], |r| {
                r.get(0)
            })
            .optional()?;
        if marker.as_deref() != Some("applied") {
            return Err("database has no Monastack seed marker; refusing to modify it".into());
        }
    }
    tx.execute_batch("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS actors(id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL); CREATE TABLE IF NOT EXISTS rooms(id TEXT PRIMARY KEY, restricted INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS room_members(room TEXT NOT NULL REFERENCES rooms(id), actor TEXT NOT NULL REFERENCES actors(id), PRIMARY KEY(room,actor)); CREATE TABLE IF NOT EXISTS tokens(hash BLOB PRIMARY KEY, actor TEXT NOT NULL REFERENCES actors(id)); CREATE TABLE IF NOT EXISTS security_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, actor TEXT NOT NULL, subject TEXT NOT NULL, action TEXT NOT NULL, created INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, scope TEXT NOT NULL, sender TEXT NOT NULL REFERENCES actors(id), body TEXT NOT NULL, created INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS messages_scope ON messages(scope,created); CREATE TABLE IF NOT EXISTS presence(session TEXT PRIMARY KEY, actor TEXT NOT NULL REFERENCES actors(id), room TEXT NOT NULL REFERENCES rooms(id), x REAL NOT NULL, y REAL NOT NULL, seq INTEGER NOT NULL, updated INTEGER NOT NULL);")?;
    let authority_id: Option<String> = tx
        .query_row(
            "SELECT value FROM metadata WHERE key='authority-id-v1'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if authority_id.is_none() {
        tx.execute(
            "INSERT INTO metadata VALUES ('authority-id-v1', ?1)",
            [uuid::Uuid::new_v4().to_string()],
        )?;
    }
    tasks::initialize(&tx)?;
    jobs::initialize(&tx)?;
    documents::initialize(&tx)?;
    customers::initialize(&tx)?;
    contracts::initialize(&tx)?;
    bookings::initialize(&tx)?;
    expenses::initialize(&tx)?;
    incidents::initialize(&tx)?;
    sales::initialize(&tx)?;
    meetings::initialize(&tx)?;
    support::initialize(&tx)?;
    journals::initialize(&tx)?;
    whiteboard::initialize(&tx)?;
    payments::initialize(&tx)?;
    hosts::initialize(&tx)?;
    leave::initialize(&tx)?;
    room_admin::initialize(&tx)?;
    let seeded: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='seed-v1')",
        [],
        |r| r.get(0),
    )?;
    if seeded {
        jobs::seed_roles(&tx, actors)?;
        customers::seed_roles(&tx, actors)?;
        tx.pragma_update(None, "user_version", 16)?;
        tx.commit()?;
        return Ok(());
    }
    for a in actors {
        tx.execute(
            "INSERT OR IGNORE INTO actors VALUES (?1,?2,?3)",
            params![
                a["id"].as_str().ok_or("actor id")?,
                a["kind"].as_str().ok_or("actor kind")?,
                a["name"].as_str().ok_or("actor name")?
            ],
        )?;
    }
    for r in rooms {
        let id = r["id"].as_str().ok_or("room id")?;
        tx.execute(
            "INSERT OR IGNORE INTO rooms VALUES (?1,?2)",
            params![id, r["restricted"].as_bool().ok_or("restricted")?],
        )?;
        for member in r["members"].as_array().ok_or("members")? {
            tx.execute(
                "INSERT OR IGNORE INTO room_members VALUES (?1,?2)",
                params![id, member.as_str().ok_or("member")?],
            )?;
        }
    }
    jobs::seed_roles(&tx, actors)?;
    customers::seed_roles(&tx, actors)?;
    tx.execute("INSERT INTO metadata VALUES ('seed-v1','applied')", [])?;
    tx.pragma_update(None, "user_version", 16)?;
    tx.commit()?;
    Ok(())
}
fn actor(db: &Connection, headers: &HeaderMap) -> Result<String, ApiError> {
    let token = headers
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
        .ok_or(err(StatusCode::UNAUTHORIZED, "authentication required"))?;
    db.query_row(
        "SELECT actor FROM tokens WHERE hash=?1",
        [hash(token)],
        |r| r.get(0),
    )
    .optional()
    .map_err(db_error)?
    .ok_or(err(StatusCode::UNAUTHORIZED, "invalid credential"))
}
fn permitted(db: &Connection, who: &str, room: &str) -> Result<bool, ApiError> {
    let restricted: Option<bool> = db
        .query_row("SELECT restricted FROM rooms WHERE id=?1", [room], |r| {
            r.get(0)
        })
        .optional()
        .map_err(db_error)?;
    let human: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1 AND kind='human')",
            [who],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    let member: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM room_members WHERE room=?1 AND actor=?2)",
            params![room, who],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    Ok(restricted
        .map(|r| monastack_core::may_enter(true, human, r, member))
        .unwrap_or(false))
}
fn scope_for(db: &Connection, who: &str, raw: &str) -> Result<String, ApiError> {
    if let Some(room) = raw.strip_prefix("room:") {
        if !permitted(db, who, room)? {
            return Err(err(StatusCode::FORBIDDEN, "room access denied"));
        }
        Ok(raw.to_string())
    } else if let Some(other) = raw.strip_prefix("dm:") {
        let valid: bool = db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1 AND kind='human')",
                [other],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        if !valid || other == who {
            return Err(err(StatusCode::FORBIDDEN, "invalid recipient"));
        }
        let mut ids = [who, other];
        ids.sort();
        Ok(format!("dm:{}:{}", ids[0], ids[1]))
    } else {
        Err(err(StatusCode::BAD_REQUEST, "invalid scope"))
    }
}
async fn me(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiError> {
    let mut db = state.lock().unwrap();
    let tx = db.transaction().map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let authority_id: String = tx
        .query_row(
            "SELECT value FROM metadata WHERE key='authority-id-v1'",
            [],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    Ok(Json(
        serde_json::json!({"actor":who, "workspace":"nviai", "authority_id":authority_id}),
    ))
}
async fn room_permissions(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<String>>, ApiError> {
    let mut db = state.lock().unwrap();
    let tx = db.transaction().map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let mut statement = tx
        .prepare("SELECT id FROM rooms ORDER BY id")
        .map_err(db_error)?;
    let ids = statement
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    let mut result = Vec::new();
    for id in ids {
        if permitted(&tx, &who, &id)? {
            result.push(id);
        }
    }
    drop(statement);
    tx.commit().map_err(db_error)?;
    Ok(Json(result))
}
#[derive(Serialize, Debug)]
struct Message {
    id: String,
    sender: String,
    body: String,
    created: i64,
}
#[derive(Deserialize)]
struct NewMessage {
    id: String,
    body: String,
}
#[derive(Default, Deserialize)]
struct MessageQuery {
    before: Option<String>,
}
async fn read_messages(
    State(state): State<Db>,
    Path(scope): Path<String>,
    headers: HeaderMap,
    Query(query): Query<MessageQuery>,
) -> Result<Json<Vec<Message>>, ApiError> {
    let mut db = state.lock().unwrap();
    let tx = db.transaction().map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let scope = scope_for(&tx, &who, &scope)?;
    let before_row = if let Some(before) = query.before {
        if before.len() < 16 || before.len() > 80 {
            return Err(err(StatusCode::BAD_REQUEST, "invalid message cursor"));
        }
        let row: Option<i64> = tx
            .query_row(
                "SELECT rowid FROM messages WHERE scope=?1 AND id=?2",
                params![scope, before],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_error)?;
        Some(row.ok_or(err(StatusCode::NOT_FOUND, "message cursor not found"))?)
    } else {
        None
    };
    let mut stmt=tx.prepare("SELECT id,sender,body,created FROM messages WHERE scope=?1 AND (?2 IS NULL OR rowid < ?2) ORDER BY rowid DESC LIMIT 200").map_err(db_error)?;
    let rows = stmt
        .query_map(params![scope, before_row], |r| {
            Ok(Message {
                id: r.get(0)?,
                sender: r.get(1)?,
                body: r.get(2)?,
                created: r.get(3)?,
            })
        })
        .map_err(db_error)?;
    let mut result = rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?;
    result.reverse();
    drop(stmt);
    tx.commit().map_err(db_error)?;
    Ok(Json(result))
}
async fn send_message(
    State(state): State<Db>,
    Path(scope): Path<String>,
    headers: HeaderMap,
    Json(m): Json<NewMessage>,
) -> Result<StatusCode, ApiError> {
    if m.id.len() < 16 || m.id.len() > 80 || m.body.trim().is_empty() || m.body.len() > 4000 {
        return Err(err(StatusCode::BAD_REQUEST, "invalid message"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let scope = scope_for(&tx, &who, &scope)?;
    let existing: Option<(String, String, String)> = tx
        .query_row(
            "SELECT scope,sender,body FROM messages WHERE id=?1",
            [&m.id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(db_error)?;
    if let Some(old) = existing {
        return if old == (scope, who, m.body) {
            Ok(StatusCode::OK)
        } else {
            Err(err(StatusCode::CONFLICT, "message id conflict"))
        };
    }
    tx.execute(
        "INSERT INTO messages VALUES (?1,?2,?3,?4,?5)",
        params![m.id, scope, who, m.body, now()],
    )
    .map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}
/// Corridors are shared space authorized and chatted in as the lobby.
const CORRIDOR_ROOM: &str = "lobby";

/// The validated office map shared by realtime presence validation.
fn office_map() -> &'static monastack_core::map::Map {
    static WORLD: std::sync::OnceLock<monastack_core::map::Map> = std::sync::OnceLock::new();
    WORLD.get_or_init(|| {
        let world: monastack_core::map::Map =
            serde_json::from_str(include_str!("../../../data/seed/nviai/map.v2.json"))
                .expect("invalid map");
        world.validate().expect("invalid map geometry");
        world
    })
}

/// Advances the access epoch observed by the realtime service. Called in the
/// same transaction as any room-membership or credential change.
fn bump_realtime_epoch(tx: &rusqlite::Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute(
        "INSERT INTO metadata(key,value) VALUES ('realtime_epoch','1') ON CONFLICT(key) DO UPDATE SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT)",
        [],
    )?;
    Ok(())
}
fn realtime_epoch(db: &Connection) -> rusqlite::Result<u64> {
    let value: Option<String> = db
        .query_row(
            "SELECT value FROM metadata WHERE key='realtime_epoch'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    Ok(value.and_then(|v| v.parse().ok()).unwrap_or(0))
}

/// Realtime epoch read directly from the authority database when the
/// realtime capability runs in the same process.
struct DbEpoch(Db);
impl realtime::EpochSource for DbEpoch {
    fn current(&self) -> Option<u64> {
        let db = self.0.lock().ok()?;
        realtime_epoch(&db).ok()
    }
}

#[derive(Clone)]
struct RealtimeConfig {
    key: realtime::TicketKey,
    /// Loopback URL clients use for presence.
    url: String,
}

#[derive(Serialize)]
struct TicketResponse {
    ticket: String,
    expires_in: i64,
    realtime_url: String,
}

/// Issues a short-lived realtime ticket listing the rooms the caller may
/// currently enter. The realtime service never sees the bearer credential.
async fn realtime_ticket(
    State(state): State<Db>,
    axum::Extension(config): axum::Extension<Option<RealtimeConfig>>,
    headers: HeaderMap,
) -> Result<Json<TicketResponse>, ApiError> {
    let config = config.ok_or(err(
        StatusCode::SERVICE_UNAVAILABLE,
        "realtime capability not configured",
    ))?;
    let mut db = state.lock().unwrap();
    let tx = db.transaction().map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let mut rooms = Vec::new();
    let ids: Vec<String> = {
        let mut stmt = tx
            .prepare("SELECT id FROM rooms ORDER BY id")
            .map_err(db_error)?;
        let rows = stmt.query_map([], |r| r.get(0)).map_err(db_error)?;
        rows.collect::<Result<_, _>>().map_err(db_error)?
    };
    for id in ids {
        if permitted(&tx, &who, &id)? {
            rooms.push(id);
        }
    }
    let epoch = realtime_epoch(&tx).map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    let issued = now();
    let ticket = realtime::Ticket {
        v: realtime::TICKET_VERSION,
        actor: who,
        rooms,
        epoch,
        iat: issued,
        exp: issued + realtime::TICKET_SECONDS,
    };
    Ok(Json(TicketResponse {
        ticket: realtime::sign(&config.key, &ticket),
        expires_in: realtime::TICKET_SECONDS,
        realtime_url: config.url,
    }))
}

async fn realtime_epoch_handler(
    State(state): State<Db>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let db = state.lock().unwrap();
    let epoch = realtime_epoch(&db).map_err(db_error)?;
    Ok(Json(serde_json::json!({ "epoch": epoch })))
}

fn loopback_port(name: &str, default: u16) -> Result<u16, Box<dyn std::error::Error>> {
    Ok(env::var(name)
        .unwrap_or_else(|_| default.to_string())
        .parse()?)
}

/// Standalone realtime service: no database, epoch polled from the authority.
async fn serve_realtime() -> Result<(), Box<dyn std::error::Error>> {
    let key = realtime::TicketKey::from_env()?
        .ok_or("MONASTACK_REALTIME_KEY_FILE is required for the realtime service")?;
    let authority = std::net::SocketAddr::from((
        std::net::Ipv4Addr::LOCALHOST,
        loopback_port("MONASTACK_NODE_PORT", 47830)?,
    ));
    let port = loopback_port("MONASTACK_REALTIME_PORT", 47831)?;
    if port == 0 {
        return Err("MONASTACK_REALTIME_PORT must be nonzero".into());
    }
    let epoch = realtime::PolledEpoch::new();
    tokio::spawn(realtime::poll_epoch(authority, epoch.clone()));
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port)).await?;
    eprintln!("realtime service listening on loopback:{port}");
    axum::serve(
        listener,
        realtime::router(realtime::Realtime::new(key, epoch)),
    )
    .await?;
    Ok(())
}
/// Copy a SQLite snapshot into a new destination without replacing existing files.
fn copy_database(
    source: &std::path::Path,
    destination: &std::path::Path,
) -> Result<(), Box<dyn std::error::Error>> {
    use std::os::unix::fs::OpenOptionsExt;
    if !source.is_file() {
        return Err("source database does not exist or is not a regular file".into());
    }
    let source_db =
        Connection::open_with_flags(source, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let integrity: String = source_db.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
    if integrity != "ok" {
        return Err("source database failed integrity check".into());
    }
    let seeded: Option<String> = source_db
        .query_row("SELECT value FROM metadata WHERE key='seed-v1'", [], |r| {
            r.get(0)
        })
        .optional()?;
    if seeded.as_deref() != Some("applied") {
        return Err("source is not a seeded Monastack database".into());
    }
    for suffix in ["-wal", "-shm", "-journal"] {
        let mut sibling = destination.as_os_str().to_os_string();
        sibling.push(suffix);
        if std::fs::symlink_metadata(sibling).is_ok() {
            return Err("destination SQLite sidecar already exists".into());
        }
    }
    let file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(destination)?;
    drop(file);
    source_db.backup("main", destination, None)?;
    let check =
        Connection::open_with_flags(destination, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let result: String = check.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
    if result != "ok" {
        return Err("destination database failed integrity check".into());
    }
    Ok(())
}
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    let path = env::var("MONASTACK_DB").unwrap_or_else(|_| "office.sqlite3".into());
    match args.get(1).map(String::as_str) {
        None if args.len()==1 => {},
        Some("realtime") if args.len()==2 => return serve_realtime().await,
        Some("enroll") if args.len()==3 => {},
        Some("host-enroll") if args.len()==5 => {
            if !std::path::Path::new(&path).is_file() { return Err("database does not exist; refusing host enrollment".into()); }
        },
        Some("host-revoke") if args.len()==3 => {
            if !std::path::Path::new(&path).is_file() { return Err("database does not exist; refusing host revocation".into()); }
        },
        Some("host-claims") if args.len()==3 && matches!(args[2].as_str(),"enable"|"disable") => {
            if !std::path::Path::new(&path).is_file() { return Err("database does not exist; refusing host setting change".into()); }
        },
        Some("role") if args.len()==5 && matches!(args[2].as_str(), "grant" | "revoke") && matches!(args[3].as_str(), "hr" | "operations") => {
            if !std::path::Path::new(&path).is_file() { return Err("database does not exist; refusing to create it for role change".into()); }
        },
        Some("room") if args.len()==5 && matches!(args[2].as_str(), "grant" | "revoke") => {
            if !std::path::Path::new(&path).is_file() { return Err("database does not exist; refusing to create it for room change".into()); }
        },
        Some("revoke") if args.len()==2 => {
            if !std::path::Path::new(&path).is_file() { return Err("database does not exist; refusing to create it for revocation".into()); }
        },
        Some("backup" | "restore") if args.len()==3 => {},
        _ => return Err("usage: office-node [realtime | enroll ACTOR | revoke | role grant|revoke hr|operations ACTOR | room grant|revoke ROOM ACTOR | host-enroll HOST HUMAN AGENT | host-revoke HOST | host-claims enable|disable | backup NEW_DESTINATION | restore SNAPSHOT]".into()),
    }
    if args.get(1).map(String::as_str) == Some("backup") {
        let destination = args
            .get(2)
            .ok_or("usage: office-node backup NEW_DESTINATION")?;
        copy_database(
            std::path::Path::new(&path),
            std::path::Path::new(destination),
        )?;
        eprintln!("Backup created and checked");
        return Ok(());
    }
    if args.get(1).map(String::as_str) == Some("restore") {
        let source = args
            .get(2)
            .ok_or("usage: office-node restore SNAPSHOT (MONASTACK_DB must not exist)")?;
        copy_database(std::path::Path::new(source), std::path::Path::new(&path))?;
        eprintln!("Restore created and checked");
        return Ok(());
    }
    let mut db = Connection::open(path)?;
    db.busy_timeout(std::time::Duration::from_secs(2))?;
    db.execute_batch("PRAGMA foreign_keys=ON;")?;
    initialize(
        &mut db,
        include_str!("../../../data/seed/nviai/seed.v1.json"),
    )?;
    db.execute_batch("PRAGMA journal_mode=WAL;")?;
    if args.get(1).map(String::as_str) == Some("host-enroll") {
        let (id, sponsor, agent) = (&args[2], &args[3], &args[4]);
        if !(16..=80).contains(&id.len())
            || !id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err("invalid host id".into());
        }
        let mut token = String::new();
        io::stdin().read_to_string(&mut token)?;
        let token = token.trim();
        if !(32..=256).contains(&token.len())
            || !token
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        {
            return Err(
                "host token must be 32–256 ASCII letters, digits, hyphens or underscores on stdin"
                    .into(),
            );
        }
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let human: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1 AND kind='human')",
            [sponsor],
            |r| r.get(0),
        )?;
        let agent_exists: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1 AND kind='agent')",
            [agent],
            |r| r.get(0),
        )?;
        let token_is_human: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM tokens WHERE hash=?1)",
            [hash(token)],
            |r| r.get(0),
        )?;
        if !human || !agent_exists || token_is_human {
            return Err("invalid sponsor, agent, or credential already used by a human".into());
        }
        tx.execute("INSERT INTO host_credentials(id,token_hash,sponsor,agent,enabled) VALUES (?1,?2,?3,?4,1)",params![id,hash(token),sponsor,agent])?;
        tx.execute("INSERT INTO security_audit(actor,subject,action,created) VALUES ('local-operator',?1,'host_enrolled',?2)",params![id,now()])?;
        tx.commit()?;
        return Ok(());
    }
    if args.get(1).map(String::as_str) == Some("host-revoke") {
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let changed = tx.execute(
            "UPDATE host_credentials SET enabled=0 WHERE id=?1 AND enabled=1",
            [&args[2]],
        )?;
        if changed != 1 {
            return Err("host not found or already revoked".into());
        }
        tx.execute("INSERT INTO security_audit(actor,subject,action,created) VALUES ('local-operator',?1,'host_revoked',?2)",params![args[2],now()])?;
        tx.commit()?;
        return Ok(());
    }
    if args.get(1).map(String::as_str) == Some("host-claims") {
        let next = if args[2] == "enable" { "true" } else { "false" };
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let changed = tx.execute(
            "UPDATE metadata SET value=?1 WHERE key='host-claims-enabled-v1' AND value != ?1",
            [next],
        )?;
        if changed != 1 {
            return Err("host claims already have the requested state".into());
        }
        if next == "false" {
            tx.execute("UPDATE host_claims SET deadline=0 WHERE job IN (SELECT id FROM agent_jobs WHERE state='host_claimed')", [])?;
        }
        tx.execute("INSERT INTO security_audit(actor,subject,action,created) VALUES ('local-operator','host-claims',?1,?2)",params![format!("host_claims_{}",args[2]),now()])?;
        tx.commit()?;
        return Ok(());
    }
    if args.get(1).map(String::as_str) == Some("room") {
        let action = &args[2];
        let room = &args[3];
        let name = &args[4];
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let restricted: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM rooms WHERE id=?1 AND restricted=1)",
            [room],
            |r| r.get(0),
        )?;
        let human: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1 AND kind='human')",
            [name],
            |r| r.get(0),
        )?;
        if !restricted || !human {
            return Err("unknown human or restricted room".into());
        }
        let version = room_admin::membership_version(&tx, room)?;
        if version == i64::MAX {
            return Err("room membership version exhausted".into());
        }
        let changed = if action == "grant" {
            tx.execute(
                "INSERT OR IGNORE INTO room_members(room,actor) VALUES (?1,?2)",
                params![room, name],
            )?
        } else {
            tx.execute(
                "DELETE FROM room_members WHERE room=?1 AND actor=?2",
                params![room, name],
            )?
        };
        if changed != 1 {
            return Err("room membership already has the requested state".into());
        }
        room_admin::advance_version(&tx, room, version)?;
        tx.execute("INSERT INTO security_audit(actor,subject,action,created) VALUES ('local-operator',?1,?2,?3)", params![name,format!("room_{action}:{room}"),now()])?;
        tx.commit()?;
        return Ok(());
    }
    if args.get(1).map(String::as_str) == Some("role") {
        let action = &args[2];
        let role = &args[3];
        let name = &args[4];
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let human: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1 AND kind='human')",
            [name],
            |r| r.get(0),
        )?;
        if !human {
            return Err("unknown human actor".into());
        }
        let changed = if action == "grant" {
            tx.execute(
                "INSERT OR IGNORE INTO actor_roles(actor,role) VALUES (?1,?2)",
                params![name, role],
            )?
        } else {
            tx.execute(
                "DELETE FROM actor_roles WHERE actor=?1 AND role=?2",
                params![name, role],
            )?
        };
        if changed != 1 {
            return Err("role already has the requested state".into());
        }
        tx.execute("INSERT INTO security_audit(actor,subject,action,created) VALUES ('local-operator',?1,?2,?3)", params![name,format!("role_{action}:{role}"),now()])?;
        tx.commit()?;
        return Ok(());
    }
    if args.get(1).map(String::as_str) == Some("enroll") {
        let name = args
            .get(2)
            .ok_or("usage: office-node enroll ACTOR (token on stdin)")?;
        let mut token = String::new();
        io::stdin().read_to_string(&mut token)?;
        let token = token.trim();
        if token.len() < 32 {
            return Err("token must be at least 32 characters".into());
        }
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let human: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1 AND kind='human')",
            [name],
            |r| r.get(0),
        )?;
        if !human {
            return Err("unknown human actor".into());
        }
        let host_token: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM host_credentials WHERE token_hash=?1)",
            [hash(token)],
            |r| r.get(0),
        )?;
        if host_token {
            return Err("credential already used by a host".into());
        }
        tx.execute(
            "INSERT INTO tokens VALUES (?1,?2)",
            params![hash(token), name],
        )?;
        tx.execute("INSERT INTO security_audit(actor,subject,action,created) VALUES ('local-operator',?1,'credential_enrolled',?2)",params![name,now()])?;
        tx.commit()?;
        return Ok(());
    }
    if args.get(1).map(String::as_str) == Some("revoke") {
        let mut token = String::new();
        io::stdin().read_to_string(&mut token)?;
        let token = token.trim();
        if token.len() < 32 {
            return Err("credential must be provided on stdin".into());
        }
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let principal: Option<String> = tx
            .query_row(
                "SELECT actor FROM tokens WHERE hash=?1",
                [hash(token)],
                |r| r.get(0),
            )
            .optional()?;
        let principal = principal.ok_or("credential not found")?;
        tx.execute("DELETE FROM tokens WHERE hash=?1", [hash(token)])?;
        bump_realtime_epoch(&tx)?;
        tx.execute("INSERT INTO security_audit(actor,subject,action,created) VALUES ('local-operator',?1,'credential_revoked',?2)",params![principal,now()])?;
        tx.commit()?;
        return Ok(());
    }
    let state = Arc::new(Mutex::new(db));
    let app = Router::new()
        .route("/v1/host/jobs", get(hosts::jobs))
        .route("/v1/host/claim", axum::routing::post(hosts::claim))
        .route("/v1/host/jobs/{job}/control", get(hosts::control))
        .route(
            "/v1/host/jobs/{job}/report",
            axum::routing::post(hosts::report),
        )
        .route("/v1/finance/capabilities", get(payments::capabilities))
        .route(
            "/v1/payment-authorizations",
            get(payments::list).post(payments::create),
        )
        .route(
            "/v1/payment-authorizations/{payment}/history",
            get(payments::history),
        )
        .route(
            "/v1/payment-authorizations/{payment}/decision",
            axum::routing::post(payments::decision),
        )
        .route(
            "/v1/whiteboard/notes",
            get(whiteboard::list).post(whiteboard::create),
        )
        .route(
            "/v1/whiteboard/notes/{note}",
            axum::routing::post(whiteboard::update),
        )
        .route(
            "/v1/whiteboard/notes/{note}/history",
            get(whiteboard::history),
        )
        .route("/v1/journals", get(journals::list).post(journals::create))
        .route("/v1/journals/balances", get(journals::balances))
        .route("/v1/journals/trial-balance", get(journals::trial_balance))
        .route(
            "/v1/journals/{journal}/reverse",
            axum::routing::post(journals::reverse),
        )
        .route("/v1/journals/{journal}/history", get(journals::history))
        .route(
            "/v1/journals/{journal}/decision",
            axum::routing::post(journals::decision),
        )
        .route("/v1/cases", get(support::list).post(support::create))
        .route("/v1/bookings", get(bookings::list).post(bookings::create))
        .route("/v1/bookings/capabilities", get(bookings::capabilities))
        .route(
            "/v1/bookings/{booking}",
            axum::routing::post(bookings::reschedule),
        )
        .route("/v1/bookings/{booking}/history", get(bookings::history))
        .route(
            "/v1/bookings/{booking}/cancel",
            axum::routing::post(bookings::cancel),
        )
        .route(
            "/v1/contracts",
            get(contracts::list).post(contracts::create),
        )
        .route("/v1/contracts/capabilities", get(contracts::capabilities))
        .route("/v1/contracts/{contract}/history", get(contracts::history))
        .route(
            "/v1/contracts/{contract}/decision",
            axum::routing::post(contracts::decision),
        )
        .route("/v1/cases/{case}/history", get(support::history))
        .route(
            "/v1/cases/{case}/transition",
            axum::routing::post(support::transition),
        )
        .route("/v1/support/capabilities", get(support::capabilities))
        .route("/v1/meetings", get(meetings::list).post(meetings::create))
        .route(
            "/v1/meetings/{meeting}",
            axum::routing::post(meetings::reschedule),
        )
        .route(
            "/v1/meetings/{meeting}/cancel",
            axum::routing::post(meetings::cancel),
        )
        .route("/v1/meetings/{meeting}/history", get(meetings::history))
        .route("/v1/sales/capabilities", get(sales::capabilities))
        .route("/v1/opportunities", get(sales::list).post(sales::create))
        .route(
            "/v1/opportunities/{opportunity}/history",
            get(sales::history),
        )
        .route(
            "/v1/opportunities/{opportunity}/transition",
            axum::routing::post(sales::transition),
        )
        .route(
            "/v1/incidents",
            get(incidents::list).post(incidents::create),
        )
        .route("/v1/incidents/{incident}/history", get(incidents::history))
        .route(
            "/v1/incidents/{incident}/comments",
            get(incidents::comments).post(incidents::add_comment),
        )
        .route(
            "/v1/incidents/{incident}/transition",
            axum::routing::post(incidents::transition),
        )
        .route("/v1/leave", get(leave::list).post(leave::create))
        .route("/v1/leave/calendar", get(leave::calendar))
        .route("/v1/leave/{request}/history", get(leave::history))
        .route(
            "/v1/leave/{request}/decision",
            axum::routing::post(leave::decision),
        )
        .route("/v1/expenses", get(expenses::list).post(expenses::create))
        .route("/v1/expenses/{expense}/history", get(expenses::history))
        .route(
            "/v1/expenses/{expense}/decision",
            axum::routing::post(expenses::decision),
        )
        .route(
            "/v1/customers",
            get(customers::list).post(customers::create),
        )
        .route(
            "/v1/customers/{customer}",
            get(customers::read).post(customers::update),
        )
        .route(
            "/v1/documents",
            get(documents::list).post(documents::create),
        )
        .route(
            "/v1/documents/{document}",
            get(documents::read).post(documents::update),
        )
        .route("/v1/documents/{document}/history", get(documents::history))
        .route("/v1/jobs", get(jobs::list).post(jobs::create))
        .route("/v1/jobs/{job}/history", get(jobs::history))
        .route(
            "/v1/jobs/{job}/decision",
            axum::routing::post(jobs::decision),
        )
        .route(
            "/v1/projects",
            get(tasks::projects).post(tasks::create_project),
        )
        .route(
            "/v1/projects/{project}/tasks",
            get(tasks::list_tasks).post(tasks::create_task),
        )
        .route(
            "/v1/tasks/{task}/transition",
            axum::routing::post(tasks::transition),
        )
        .route(
            "/v1/tasks/{task}/comments",
            get(tasks::comments).post(tasks::add_comment),
        )
        .route(
            "/v1/projects/{project}/members",
            get(tasks::members).post(tasks::change_member),
        )
        .route(
            "/v1/projects/{project}/history",
            get(tasks::project_history),
        )
        .route("/v1/tasks/{task}/history", get(tasks::history))
        .route(
            "/v1/tasks/{task}/assign",
            axum::routing::post(tasks::assign),
        )
        .route("/v1/me", get(me))
        .route("/v1/rooms", get(room_permissions))
        .route("/v1/room-admin/capabilities", get(room_admin::capabilities))
        .route(
            "/v1/room-admin/{room}/members",
            get(room_admin::members).post(room_admin::change),
        )
        .route("/v1/room-admin/{room}/history", get(room_admin::history))
        .route(
            "/v1/messages/{scope}",
            get(read_messages).post(send_message),
        )
        .route("/v1/realtime/ticket", axum::routing::post(realtime_ticket))
        .route("/v1/realtime/epoch", get(realtime_epoch_handler))
        .with_state(state.clone());
    let port: u16 = env::var("MONASTACK_NODE_PORT")
        .unwrap_or_else(|_| "47830".into())
        .parse()?;
    if port == 0 {
        return Err("MONASTACK_NODE_PORT must be nonzero".into());
    }
    // Realtime presence runs in this process by default on its own loopback
    // port (MONASTACK_REALTIME_PORT, ephemeral when unset), with a fresh key
    // and the epoch read from this database. `external` advertises a
    // separately started `office-node realtime` service instead.
    let config = match env::var("MONASTACK_REALTIME").as_deref() {
        Ok("off") => None,
        Ok("external") => Some(RealtimeConfig {
            key: realtime::TicketKey::from_env()?
                .ok_or("MONASTACK_REALTIME_KEY_FILE is required for external realtime")?,
            url: format!(
                "http://127.0.0.1:{}",
                loopback_port("MONASTACK_REALTIME_PORT", 47831)?
            ),
        }),
        Ok("embedded") | Err(_) => {
            let key = realtime::TicketKey::from_env()?.unwrap_or_else(realtime::TicketKey::random);
            let listener = tokio::net::TcpListener::bind((
                std::net::Ipv4Addr::LOCALHOST,
                loopback_port("MONASTACK_REALTIME_PORT", 0)?,
            ))
            .await?;
            let realtime_port = listener.local_addr()?.port();
            let mut service =
                realtime::Realtime::new(key.clone(), Arc::new(DbEpoch(state.clone())));
            if let Some(config) = media::MediaConfig::from_env()? {
                service = service.with_media(media::MediaControl::new(config));
            }
            tokio::spawn(async move {
                if let Err(error) = axum::serve(listener, realtime::router(service)).await {
                    eprintln!("realtime service stopped: {error}");
                }
            });
            eprintln!("realtime presence listening on loopback:{realtime_port}");
            Some(RealtimeConfig {
                key,
                url: format!("http://127.0.0.1:{realtime_port}"),
            })
        }
        Ok(_) => return Err("MONASTACK_REALTIME must be embedded, external or off".into()),
    };
    let app = app.layer(axum::Extension(config));
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port)).await?;
    eprintln!("office node listening on loopback:{port}");
    axum::serve(listener, app).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    const SEED: &str = include_str!("../../../data/seed/nviai/seed.v1.json");
    fn setup() -> Db {
        let mut db = Connection::open_in_memory().unwrap();
        db.execute_batch("PRAGMA foreign_keys=ON").unwrap();
        initialize(&mut db, SEED).unwrap();
        for who in ["an", "van", "mai"] {
            db.execute("INSERT INTO tokens VALUES (?1,?2)", params![hash(who), who])
                .unwrap();
        }
        Arc::new(Mutex::new(db))
    }
    fn headers(who: &str) -> HeaderMap {
        let mut h = HeaderMap::new();
        h.insert("authorization", format!("Bearer {who}").parse().unwrap());
        h
    }
    #[test]
    fn unrelated_and_newer_databases_are_not_modified() {
        let mut foreign = Connection::open_in_memory().unwrap();
        foreign.execute_batch("CREATE TABLE personal_data(value TEXT); INSERT INTO personal_data VALUES ('keep');").unwrap();
        assert!(initialize(&mut foreign, SEED).is_err());
        let value: String = foreign
            .query_row("SELECT value FROM personal_data", [], |r| r.get(0))
            .unwrap();
        assert_eq!(value, "keep");
        let created: bool = foreign
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='actors')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(!created);
        let mut newer = Connection::open_in_memory().unwrap();
        newer.execute_batch("PRAGMA user_version=99").unwrap();
        assert!(initialize(&mut newer, SEED).is_err());
        let version: i64 = newer
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, 99);
    }
    #[test]
    fn seed_twice_preserves_revocation() {
        let db = setup();
        let mut c = db.lock().unwrap();
        c.execute(
            "DELETE FROM room_members WHERE room='finance' AND actor='van'",
            [],
        )
        .unwrap();
        c.execute_batch("DROP TABLE room_membership_ops; DROP TABLE room_membership_versions; PRAGMA user_version=15;")
            .unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert!(!permitted(&c, "van", "finance").unwrap());
        assert_eq!(
            c.query_row("SELECT COUNT(*) FROM room_membership_ops", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        c.execute_batch("CREATE TABLE user_extension(value TEXT); INSERT INTO user_extension VALUES ('preserve'); PRAGMA user_version=1;").unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert_eq!(
            c.query_row("SELECT value FROM user_extension", [], |r| r
                .get::<_, String>(0))
                .unwrap(),
            "preserve"
        );
        assert!(!permitted(&c, "van", "finance").unwrap());
        c.execute_batch("INSERT INTO incidents VALUES ('migration-incident-001','van','Synthetic migration','Details','low','open',1,1); DROP TABLE incident_comments; PRAGMA user_version=12;").unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert_eq!(
            c.query_row(
                "SELECT COUNT(*) FROM incidents WHERE id='migration-incident-001'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            1
        );
        assert_eq!(
            c.query_row("SELECT COUNT(*) FROM incident_comments", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        c.execute_batch(
            "DROP TABLE contract_audit; DROP TABLE contract_proposals; PRAGMA user_version=13;",
        )
        .unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert_eq!(
            c.query_row(
                "SELECT COUNT(*) FROM incidents WHERE id='migration-incident-001'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            1
        );
        assert_eq!(
            c.query_row("SELECT COUNT(*) FROM contract_proposals", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        c.execute_batch(
            "DROP TABLE booking_audit; DROP TABLE customer_bookings; PRAGMA user_version=14;",
        )
        .unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert_eq!(
            c.query_row(
                "SELECT COUNT(*) FROM incidents WHERE id='migration-incident-001'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            1
        );
        assert_eq!(
            c.query_row("SELECT COUNT(*) FROM customer_bookings", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        c.execute_batch("DROP TABLE host_reports; DROP TABLE host_claims; DROP TABLE host_credentials; PRAGMA user_version=11;").unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert!(!permitted(&c, "van", "finance").unwrap());
        c.execute_batch(
            "DROP TABLE payment_audit; DROP TABLE payment_authorizations; PRAGMA user_version=10;",
        )
        .unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert!(!permitted(&c, "van", "finance").unwrap());
        c.execute_batch(
            "DROP TABLE whiteboard_audit; DROP TABLE whiteboard_notes; PRAGMA user_version=9;",
        )
        .unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert!(!permitted(&c, "van", "finance").unwrap());
        c.execute_batch("DROP TABLE journal_reversals; PRAGMA user_version=8;")
            .unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert!(!permitted(&c, "van", "finance").unwrap());
        c.execute_batch(
            "DROP TABLE journal_audit; DROP TABLE journal_entries; PRAGMA user_version=7;",
        )
        .unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert!(!permitted(&c, "van", "finance").unwrap());
        c.execute_batch(
            "DROP TABLE support_case_audit; DROP TABLE support_cases; PRAGMA user_version=6;",
        )
        .unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert!(!permitted(&c, "van", "finance").unwrap());
        c.execute_batch("DROP TABLE project_readers; PRAGMA user_version=5;")
            .unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert!(!permitted(&c, "van", "finance").unwrap());
        c.execute_batch("DROP TABLE meeting_audit; DROP TABLE meetings; PRAGMA user_version=4;")
            .unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert!(!permitted(&c, "van", "finance").unwrap());
        c.execute_batch("PRAGMA user_version=3;").unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert!(!permitted(&c, "van", "finance").unwrap());
        c.execute_batch("PRAGMA user_version=2;").unwrap();
        initialize(&mut c, SEED).unwrap();
        assert_eq!(
            c.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            16
        );
        assert!(!permitted(&c, "van", "finance").unwrap());
        let n: i64 = c
            .query_row("SELECT count(*) FROM actors", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 17);
    }
    #[tokio::test]
    async fn chat_denial_idempotency_dm_and_revocation() {
        let db = setup();
        let scope = "room:finance".to_string();
        let m = || {
            Json(NewMessage {
                id: "0123456789abcdef".into(),
                body: "private".into(),
            })
        };
        assert_eq!(
            send_message(State(db.clone()), Path(scope.clone()), headers("an"), m())
                .await
                .unwrap_err()
                .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            send_message(State(db.clone()), Path(scope.clone()), headers("van"), m())
                .await
                .unwrap(),
            StatusCode::CREATED
        );
        assert_eq!(
            send_message(State(db.clone()), Path(scope.clone()), headers("van"), m())
                .await
                .unwrap(),
            StatusCode::OK
        );
        assert_eq!(
            read_messages(
                State(db.clone()),
                Path(scope.clone()),
                headers("van"),
                Query(MessageQuery::default())
            )
            .await
            .unwrap()
            .0
            .len(),
            1
        );
        let dm = Path("dm:mai".to_string());
        assert_eq!(
            send_message(
                State(db.clone()),
                dm,
                headers("an"),
                Json(NewMessage {
                    id: "abcdef0123456789".into(),
                    body: "hello".into()
                })
            )
            .await
            .unwrap(),
            StatusCode::CREATED
        );
        assert_eq!(
            read_messages(
                State(db.clone()),
                Path("dm:an".into()),
                headers("mai"),
                Query(MessageQuery::default())
            )
            .await
            .unwrap()
            .0
            .len(),
            1
        );
        assert_eq!(
            read_messages(
                State(db.clone()),
                Path("dm:mai".into()),
                headers("van"),
                Query(MessageQuery::default())
            )
            .await
            .unwrap()
            .0
            .len(),
            0
        );
        db.lock()
            .unwrap()
            .execute(
                "DELETE FROM room_members WHERE room='finance' AND actor='van'",
                [],
            )
            .unwrap();
        assert_eq!(
            read_messages(
                State(db.clone()),
                Path(scope),
                headers("van"),
                Query(MessageQuery::default())
            )
            .await
            .unwrap_err()
            .0,
            StatusCode::FORBIDDEN
        );
    }
    #[tokio::test]
    async fn chat_history_cursor_is_scoped_and_returns_older_pages() {
        let db = setup();
        {
            let conn = db.lock().unwrap();
            for i in 0..205 {
                conn.execute(
                    "INSERT INTO messages(id,scope,sender,body,created) VALUES (?1,'room:lobby','an',?2,1)",
                    params![format!("synthetic-message-{i:04}"), format!("message {i}")],
                ).unwrap();
            }
            conn.execute("INSERT INTO messages(id,scope,sender,body,created) VALUES ('synthetic-private-0001','room:finance','van','private',1)", []).unwrap();
        }
        let latest = read_messages(
            State(db.clone()),
            Path("room:lobby".into()),
            headers("an"),
            Query(MessageQuery::default()),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(latest.len(), 200);
        assert_eq!(latest.first().unwrap().id, "synthetic-message-0005");
        let older = read_messages(
            State(db.clone()),
            Path("room:lobby".into()),
            headers("an"),
            Query(MessageQuery {
                before: Some(latest.first().unwrap().id.clone()),
            }),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(older.len(), 5);
        assert_eq!(older.first().unwrap().id, "synthetic-message-0000");
        assert_eq!(older.last().unwrap().id, "synthetic-message-0004");
        assert_eq!(
            read_messages(
                State(db.clone()),
                Path("room:lobby".into()),
                headers("an"),
                Query(MessageQuery {
                    before: Some("synthetic-private-0001".into())
                })
            )
            .await
            .unwrap_err()
            .0,
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            read_messages(
                State(db.clone()),
                Path("room:finance".into()),
                headers("an"),
                Query(MessageQuery {
                    before: Some("synthetic-private-0001".into())
                })
            )
            .await
            .unwrap_err()
            .0,
            StatusCode::FORBIDDEN
        );
    }
    async fn ticket_headers(db: &Db, config: &RealtimeConfig, who: &str) -> HeaderMap {
        let ticket = realtime_ticket(
            State(db.clone()),
            axum::Extension(Some(config.clone())),
            headers(who),
        )
        .await
        .unwrap()
        .0
        .ticket;
        let mut h = HeaderMap::new();
        h.insert("authorization", format!("Ticket {ticket}").parse().unwrap());
        h
    }
    #[tokio::test]
    async fn realtime_presence_uses_tickets_and_revokes_by_epoch() {
        use realtime::{presence, update_presence, UpdatePresence};
        let db = setup();
        let config = RealtimeConfig {
            key: realtime::TicketKey::random(),
            url: "http://127.0.0.1:1".into(),
        };
        let rt = realtime::Realtime::new(config.key.clone(), Arc::new(DbEpoch(db.clone())));
        let an = ticket_headers(&db, &config, "an").await;
        let van = ticket_headers(&db, &config, "van").await;
        let update = |seq| {
            Json(UpdatePresence {
                session: "0123456789abcdef".into(),
                room: "finance".into(),
                x: 25.,
                y: 23.,
                seq,
            })
        };
        let at = |room: &str, x, y| {
            Json(UpdatePresence {
                session: "abcdef0123456789".into(),
                room: room.into(),
                x,
                y,
                seq: 1,
            })
        };
        // A finance cell reported as the lobby, a wall, and a private room
        // without membership are all refused.
        for (headers, body) in [
            (an.clone(), at("lobby", 25., 23.)),
            (an.clone(), at("lobby", 0., 0.)),
            (an.clone(), at("finance", 25., 23.)),
        ] {
            assert_eq!(
                update_presence(State(rt.clone()), headers, body)
                    .await
                    .unwrap_err()
                    .0,
                StatusCode::FORBIDDEN
            );
        }
        // Corridors are reported as the lobby.
        assert!(
            update_presence(State(rt.clone()), an.clone(), at("lobby", 9., 9.))
                .await
                .is_ok()
        );
        assert!(update_presence(State(rt.clone()), van.clone(), update(1))
            .await
            .is_ok());
        assert_eq!(
            update_presence(State(rt.clone()), van.clone(), update(1))
                .await
                .unwrap_err()
                .0,
            StatusCode::CONFLICT
        );
        let seen =
            |list: Vec<realtime::Presence>| list.into_iter().map(|p| p.actor).collect::<Vec<_>>();
        assert_eq!(
            seen(presence(State(rt.clone()), an.clone()).await.unwrap().0),
            ["an"]
        );
        let mut visible = seen(presence(State(rt.clone()), van.clone()).await.unwrap().0);
        visible.sort();
        assert_eq!(visible, ["an", "van"]);
        // A bearer token or a forged ticket is not a realtime credential.
        let mut forged = HeaderMap::new();
        forged.insert("authorization", "Ticket 00.00".parse().unwrap());
        for headers in [headers("van"), forged] {
            assert_eq!(
                presence(State(rt.clone()), headers).await.unwrap_err().0,
                StatusCode::UNAUTHORIZED
            );
        }
        // Revoking membership advances the epoch: the old ticket and the
        // presence written under it stop working before the ticket expires.
        {
            let mut conn = db.lock().unwrap();
            let tx = conn.transaction().unwrap();
            tx.execute(
                "DELETE FROM room_members WHERE room='finance' AND actor='van'",
                [],
            )
            .unwrap();
            let version = room_admin::membership_version(&tx, "finance").unwrap();
            room_admin::advance_version(&tx, "finance", version).unwrap();
            tx.commit().unwrap();
        }
        assert_eq!(
            presence(State(rt.clone()), van.clone())
                .await
                .unwrap_err()
                .0,
            StatusCode::UNAUTHORIZED
        );
        let van = ticket_headers(&db, &config, "van").await;
        assert!(presence(State(rt.clone()), van.clone())
            .await
            .unwrap()
            .0
            .is_empty());
        assert_eq!(
            update_presence(State(rt.clone()), van.clone(), update(2))
                .await
                .unwrap_err()
                .0,
            StatusCode::FORBIDDEN
        );
    }
}
