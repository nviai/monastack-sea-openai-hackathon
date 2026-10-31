//! Workspace identity (ADR 0008): company setup, accounts with passwords,
//! device sessions with short access tokens and rotating refresh tokens,
//! invitations, and identity federation from a master node to member nodes.
//!
//! The node where the company is set up becomes the identity **master**. It
//! alone holds password hashes, refresh tokens and the signing key. Access
//! tokens are Ed25519-signed, so any node of the workspace can check them
//! with the public key. **Member** nodes join with a one-time code, pull the
//! directory (people, accounts, recent revocations) every few seconds, and
//! forward sign-in and account administration to the master.
use super::{bump_realtime_epoch, db_error, err, hash, now, ApiError, Db};
use argon2::{
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use axum::{
    body::Body,
    extract::{Path, Request, State},
    http::{HeaderMap, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    Json,
};
use base64::Engine;
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use rand_core::{OsRng, RngCore};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Access tokens are short so that a member node that cannot reach the
/// master stops accepting them soon.
pub const ACCESS_SECONDS: i64 = 600;
/// A session ends after this long without a refresh.
pub const REFRESH_SECONDS: i64 = 30 * 24 * 3600;
const INVITE_SECONDS: i64 = 7 * 24 * 3600;
const NODE_CODE_SECONDS: i64 = 3600;
/// Failed sign-ins before the account is locked, and the first lock length.
const LOCK_AFTER: i64 = 5;
const LOCK_SECONDS: i64 = 30;
const MAX_LOCK_SECONDS: i64 = 900;
const MIN_PASSWORD: usize = 10;
/// How often a member node pulls the directory from the master.
pub const SYNC_SECONDS: u64 = 5;

pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS accounts(actor TEXT PRIMARY KEY REFERENCES actors(id), username TEXT NOT NULL UNIQUE COLLATE NOCASE, password_hash TEXT, created INTEGER NOT NULL, disabled INTEGER NOT NULL DEFAULT 0, failures INTEGER NOT NULL DEFAULT 0, locked_until INTEGER NOT NULL DEFAULT 0);
         CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY, actor TEXT NOT NULL REFERENCES actors(id), device TEXT NOT NULL, platform TEXT NOT NULL, created INTEGER NOT NULL, last_seen INTEGER NOT NULL, refresh_hash BLOB UNIQUE, previous_refresh_hash BLOB, refresh_expires INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0, revoked_at INTEGER, revoked_reason TEXT);
         CREATE INDEX IF NOT EXISTS sessions_actor ON sessions(actor);
         CREATE TABLE IF NOT EXISTS invites(code_hash BLOB PRIMARY KEY, actor TEXT NOT NULL REFERENCES actors(id), purpose TEXT NOT NULL, created_by TEXT NOT NULL, created INTEGER NOT NULL, expires INTEGER NOT NULL, used INTEGER);
         CREATE TABLE IF NOT EXISTS identity_nodes(id TEXT PRIMARY KEY, name TEXT NOT NULL, join_code_hash BLOB UNIQUE, join_expires INTEGER NOT NULL, credential_hash BLOB UNIQUE, created INTEGER NOT NULL, joined INTEGER, last_sync INTEGER, revoked INTEGER NOT NULL DEFAULT 0);",
    )
}

/// Seed the requested demo company and human accounts once on a serving node.
/// Existing passwords, disabled flags, company identity and member nodes survive.
pub fn seed_company(db: &mut Connection, seed: &Value) -> Result<bool, Box<dyn std::error::Error>> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if role(&tx)? == Some(Role::Member) || meta(&tx, "demo-company-accounts-v1")?.is_some() {
        return Ok(false);
    }
    if role(&tx)?.is_none() {
        let key = SigningKey::generate(&mut OsRng);
        let authority = meta(&tx, "authority-id-v1")?.ok_or("missing authority identity")?;
        set_meta(&tx, "identity-signing-key", &hex::encode(key.to_bytes()))?;
        set_meta(
            &tx,
            "identity-public-key",
            &hex::encode(key.verifying_key().to_bytes()),
        )?;
        set_meta(&tx, "workspace-id", &authority)?;
        set_meta(
            &tx,
            "workspace-name",
            seed["workspace"]["name"]
                .as_str()
                .ok_or("missing company name")?,
        )?;
        set_meta(&tx, "identity-role", "master")?;
        tx.execute(
            "DELETE FROM metadata WHERE key IN ('setup-code-hash','setup-failures')",
            [],
        )?;
        audit(&tx, "seed", &authority, "workspace_seeded")?;
    }
    for person in seed["actors"].as_array().ok_or("missing actors")? {
        if person["kind"] != "human" {
            continue;
        }
        let id = person["id"].as_str().ok_or("missing actor id")?;
        let exists: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE actor=?1)",
            [id],
            |r| r.get(0),
        )?;
        if exists {
            continue;
        }
        let username = person["username"].as_str().unwrap_or(id);
        let password_hash = hash_password("NviaiSeaxOpenAIHackathon");
        tx.execute(
            "INSERT INTO accounts(actor,username,password_hash,created) VALUES (?1,?2,?3,?4)",
            params![id, username, password_hash, now()],
        )?;
        audit(&tx, "seed", id, "account_seeded")?;
    }
    set_meta(&tx, "demo-company-accounts-v1", "applied")?;
    tx.commit()?;
    Ok(true)
}

/// Update the three requested login names without changing actor IDs or credentials.
/// Member directories learn these usernames from their identity master.
pub fn migrate_seed_usernames(db: &mut Connection) -> rusqlite::Result<()> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if role(&tx)? != Some(Role::Master) || meta(&tx, "seed-login-names-v2")?.is_some() {
        return Ok(());
    }
    for (id, old, new) in [
        ("le-pha", "le-pha", "pha.le"),
        ("hua-hao", "hua-hao", "hao.hua"),
        ("hua-hao", "hao-hua", "hao.hua"),
        ("le-triet", "le-triet", "triet.le"),
    ] {
        let changed = tx.execute(
            "UPDATE accounts SET username=?3 WHERE actor=?1 AND username=?2",
            params![id, old, new],
        )?;
        if changed > 0 {
            audit(&tx, "seed", id, "username_updated")?;
        }
    }
    set_meta(&tx, "seed-login-names-v2", "applied")?;
    tx.commit()
}

// ------------------------------------------------------------------ helpers --

fn b64(bytes: impl AsRef<[u8]>) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}
fn unb64(text: &str) -> Option<Vec<u8>> {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(text)
        .ok()
}

/// A 256-bit random secret for machine use (refresh tokens, node credentials).
fn secret() -> String {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    b64(bytes)
}

/// An 80-bit code people can type: `XXXX-XXXX-XXXX-XXXX` without look-alike
/// characters. Stored only as a hash.
pub fn human_code() -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut bytes = [0u8; 16];
    OsRng.fill_bytes(&mut bytes);
    let chars: Vec<char> = bytes
        .iter()
        .map(|b| ALPHABET[(*b as usize) % ALPHABET.len()] as char)
        .collect();
    chars
        .chunks(4)
        .map(|c| c.iter().collect::<String>())
        .collect::<Vec<_>>()
        .join("-")
}
fn code_hash(code: &str) -> Vec<u8> {
    let normal: String = code
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_uppercase())
        .collect();
    hash(&normal)
}

fn meta(db: &Connection, key: &str) -> rusqlite::Result<Option<String>> {
    db.query_row("SELECT value FROM metadata WHERE key=?1", [key], |r| {
        r.get(0)
    })
    .optional()
}
fn set_meta(db: &Connection, key: &str, value: &str) -> rusqlite::Result<()> {
    db.execute(
        "INSERT INTO metadata(key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        params![key, value],
    )?;
    Ok(())
}
fn audit(tx: &Connection, by: &str, subject: &str, action: &str) -> rusqlite::Result<()> {
    tx.execute(
        "INSERT INTO security_audit(actor,subject,action,created) VALUES (?1,?2,?3,?4)",
        params![by, subject, action, now()],
    )?;
    Ok(())
}

/// The identity role of this node, if the workspace is set up.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Role {
    Master,
    Member,
}
pub fn role(db: &Connection) -> rusqlite::Result<Option<Role>> {
    Ok(match meta(db, "identity-role")?.as_deref() {
        Some("master") => Some(Role::Master),
        Some("member") => Some(Role::Member),
        _ => None,
    })
}

fn hash_password(password: &str) -> String {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .expect("argon2 hashing")
        .to_string()
}
fn verify_password(password: &str, stored: &str) -> bool {
    PasswordHash::new(stored)
        .map(|h| {
            Argon2::default()
                .verify_password(password.as_bytes(), &h)
                .is_ok()
        })
        .unwrap_or(false)
}
/// Hashing is slow on purpose; keep it off the async runtime and outside
/// the database lock.
async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    tokio::task::spawn_blocking(f).await.expect("blocking task")
}
/// Compared against when the username is unknown, so both cases take the
/// same time.
fn dummy_hash() -> &'static str {
    static HASH: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    HASH.get_or_init(|| hash_password("monastack-timing-equaliser"))
}

fn valid_username(name: &str) -> bool {
    (3..=32).contains(&name.len())
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '.' | '_' | '-'))
}
fn check_password(password: &str) -> Result<(), ApiError> {
    if password.chars().count() < MIN_PASSWORD || password.len() > 256 {
        return Err(err(
            StatusCode::BAD_REQUEST,
            "password must be at least 10 characters",
        ));
    }
    Ok(())
}
fn clean_label(text: &str, max: usize) -> String {
    text.chars()
        .filter(|c| !c.is_control())
        .take(max)
        .collect::<String>()
        .trim()
        .to_string()
}

// ------------------------------------------------------------ access tokens --

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Claims {
    pub v: u8,
    /// Workspace ID.
    pub iss: String,
    /// Actor ID.
    pub sub: String,
    /// Session ID.
    pub sid: String,
    pub iat: i64,
    pub exp: i64,
}

pub fn sign_access(key: &SigningKey, claims: &Claims) -> String {
    let payload = b64(serde_json::to_vec(claims).expect("claims"));
    let input = format!("v1.{payload}");
    let signature = key.sign(input.as_bytes());
    format!("{input}.{}", b64(signature.to_bytes()))
}

pub fn verify_access(public: &VerifyingKey, token: &str, at: i64) -> Option<Claims> {
    let rest = token.strip_prefix("v1.")?;
    let (payload, signature) = rest.split_once('.')?;
    let signature = Signature::from_slice(&unb64(signature)?).ok()?;
    public
        .verify_strict(format!("v1.{payload}").as_bytes(), &signature)
        .ok()?;
    let claims: Claims = serde_json::from_slice(&unb64(payload)?).ok()?;
    (claims.v == 1 && claims.exp > at && claims.iat <= at + 60).then_some(claims)
}

fn signing_key(db: &Connection) -> Result<SigningKey, ApiError> {
    let hex_key = meta(db, "identity-signing-key")
        .map_err(db_error)?
        .ok_or(err(
            StatusCode::CONFLICT,
            "this node does not issue sign-ins",
        ))?;
    let bytes: [u8; 32] = hex::decode(hex_key)
        .ok()
        .and_then(|b| b.try_into().ok())
        .ok_or(err(
            StatusCode::INTERNAL_SERVER_ERROR,
            "signing key damaged",
        ))?;
    Ok(SigningKey::from_bytes(&bytes))
}
fn public_key(db: &Connection) -> Result<Option<VerifyingKey>, ApiError> {
    let Some(hex_key) = meta(db, "identity-public-key").map_err(db_error)? else {
        return Ok(None);
    };
    let bytes: [u8; 32] = hex::decode(hex_key)
        .ok()
        .and_then(|b| b.try_into().ok())
        .ok_or(err(StatusCode::INTERNAL_SERVER_ERROR, "public key damaged"))?;
    VerifyingKey::from_bytes(&bytes)
        .map(Some)
        .map_err(|_| err(StatusCode::INTERNAL_SERVER_ERROR, "public key damaged"))
}
fn workspace_id(db: &Connection) -> Result<String, ApiError> {
    meta(db, "workspace-id")
        .map_err(db_error)?
        .ok_or(err(StatusCode::CONFLICT, "workspace is not set up"))
}

/// Resolves an access token to its actor. On the master the session must
/// exist and be live; a member rejects sessions it has learnt are revoked.
/// Disabled accounts are rejected everywhere.
pub fn actor_from_access(db: &Connection, token: &str) -> Result<String, ApiError> {
    Ok(claims_from_access(db, token)?.sub)
}
fn claims_from_access(db: &Connection, token: &str) -> Result<Claims, ApiError> {
    let invalid = err(StatusCode::UNAUTHORIZED, "invalid credential");
    let public = public_key(db)?.ok_or(invalid)?;
    let claims = verify_access(&public, token, now()).ok_or(invalid)?;
    if claims.iss != workspace_id(db)? {
        return Err(invalid);
    }
    let session: Option<bool> = db
        .query_row(
            "SELECT revoked FROM sessions WHERE id=?1 AND actor=?2",
            params![claims.sid, claims.sub],
            |r| r.get(0),
        )
        .optional()
        .map_err(db_error)?;
    // A member only learns about revocations; the master knows every session.
    let live = !matches!(
        (role(db).map_err(db_error)?, session),
        (_, Some(true)) | (Some(Role::Master), None)
    );
    let disabled: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE actor=?1 AND disabled=1)",
            [&claims.sub],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    let known: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1 AND kind='human')",
            [&claims.sub],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !live || disabled || !known {
        return Err(invalid);
    }
    Ok(claims)
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .and_then(|h| h.strip_prefix("Bearer "))
}
/// Account endpoints accept only signed-in sessions, not device tokens.
fn session_claims(db: &Connection, headers: &HeaderMap) -> Result<Claims, ApiError> {
    let token = bearer(headers).ok_or(err(StatusCode::UNAUTHORIZED, "authentication required"))?;
    claims_from_access(db, token)
}
fn is_admin(db: &Connection, actor: &str) -> Result<bool, ApiError> {
    db.query_row(
        "SELECT EXISTS(SELECT 1 FROM actor_roles WHERE actor=?1 AND role='org-admin')",
        [actor],
        |r| r.get(0),
    )
    .map_err(db_error)
}
fn require_admin(db: &Connection, headers: &HeaderMap) -> Result<Claims, ApiError> {
    let claims = session_claims(db, headers)?;
    if !is_admin(db, &claims.sub)? {
        return Err(err(StatusCode::FORBIDDEN, "organization admin required"));
    }
    Ok(claims)
}
fn require_master(db: &Connection) -> Result<(), ApiError> {
    match role(db).map_err(db_error)? {
        Some(Role::Master) => Ok(()),
        Some(Role::Member) => Err(err(
            StatusCode::CONFLICT,
            "this node forwards accounts to its master",
        )),
        None => Err(err(StatusCode::CONFLICT, "workspace is not set up")),
    }
}

// ----------------------------------------------------------------- sessions --

#[derive(Serialize)]
pub struct SignedIn {
    access_token: String,
    expires_in: i64,
    refresh_token: String,
    session: String,
    actor: String,
    name: String,
    username: String,
    admin: bool,
    workspace: Value,
}

fn workspace_json(db: &Connection) -> Result<Value, ApiError> {
    Ok(json!({
        "id": workspace_id(db)?,
        "name": meta(db, "workspace-name").map_err(db_error)?.unwrap_or_default(),
    }))
}

fn issue(db: &Connection, actor: &str, session: &str) -> Result<String, ApiError> {
    let issued = now();
    Ok(sign_access(
        &signing_key(db)?,
        &Claims {
            v: 1,
            iss: workspace_id(db)?,
            sub: actor.into(),
            sid: session.into(),
            iat: issued,
            exp: issued + ACCESS_SECONDS,
        },
    ))
}

fn signed_in(
    db: &Connection,
    actor: &str,
    session: &str,
    refresh: String,
) -> Result<SignedIn, ApiError> {
    let (name, username): (String, String) = db
        .query_row(
            "SELECT a.name, c.username FROM actors a JOIN accounts c ON c.actor=a.id WHERE a.id=?1",
            [actor],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(db_error)?;
    Ok(SignedIn {
        access_token: issue(db, actor, session)?,
        expires_in: ACCESS_SECONDS,
        refresh_token: refresh,
        session: session.into(),
        actor: actor.into(),
        name,
        username,
        admin: is_admin(db, actor)?,
        workspace: workspace_json(db)?,
    })
}

#[derive(Deserialize, Default)]
pub struct Device {
    #[serde(default)]
    device: String,
    #[serde(default)]
    platform: String,
}

fn open_session(tx: &Transaction<'_>, actor: &str, device: &Device) -> Result<SignedIn, ApiError> {
    let id = uuid::Uuid::new_v4().to_string();
    let refresh = secret();
    let at = now();
    let label = match clean_label(&device.device, 60) {
        l if l.is_empty() => "Unnamed device".to_string(),
        l => l,
    };
    tx.execute(
        "INSERT INTO sessions(id,actor,device,platform,created,last_seen,refresh_hash,refresh_expires) VALUES (?1,?2,?3,?4,?5,?5,?6,?7)",
        params![id, actor, label, clean_label(&device.platform, 20), at, hash(&refresh), at + REFRESH_SECONDS],
    )
    .map_err(db_error)?;
    audit(tx, actor, &id, "session_opened").map_err(db_error)?;
    signed_in(tx, actor, &id, refresh)
}

fn revoke_session(
    tx: &Transaction<'_>,
    id: &str,
    by: &str,
    reason: &str,
) -> Result<bool, ApiError> {
    let changed = tx
        .execute(
            "UPDATE sessions SET revoked=1, revoked_at=?2, revoked_reason=?3, refresh_hash=NULL WHERE id=?1 AND revoked=0",
            params![id, now(), reason],
        )
        .map_err(db_error)?;
    if changed > 0 {
        audit(tx, by, id, &format!("session_revoked:{reason}")).map_err(db_error)?;
        bump_realtime_epoch(tx).map_err(db_error)?;
    }
    Ok(changed > 0)
}
fn revoke_all(
    tx: &Transaction<'_>,
    actor: &str,
    except: Option<&str>,
    by: &str,
    reason: &str,
) -> Result<(), ApiError> {
    let ids: Vec<String> = {
        let mut stmt = tx
            .prepare("SELECT id FROM sessions WHERE actor=?1 AND revoked=0")
            .map_err(db_error)?;
        let rows = stmt
            .query_map([actor], |r| r.get(0))
            .map_err(db_error)?
            .collect::<Result<Vec<String>, _>>()
            .map_err(db_error)?;
        rows
    };
    for id in ids.iter().filter(|id| Some(id.as_str()) != except) {
        revoke_session(tx, id, by, reason)?;
    }
    Ok(())
}

// ------------------------------------------------------------ setup & state --

/// Public facts the sign-in screen needs. Before setup it also lists the
/// seeded people the first admin may choose to be.
pub async fn workspace(State(state): State<Db>) -> Result<Json<Value>, ApiError> {
    let db = state.lock().unwrap();
    let role = role(&db).map_err(db_error)?;
    let mut body = json!({
        "initialized": role.is_some(),
        "role": match role { Some(Role::Master) => "master", Some(Role::Member) => "member", None => "unconfigured" },
    });
    if role.is_some() {
        body["workspace"] = workspace_json(&db)?;
        if role == Some(Role::Member) {
            body["last_sync"] = json!(meta(&db, "identity-synced")
                .map_err(db_error)?
                .and_then(|v| v.parse::<i64>().ok()));
        }
    } else {
        let mut stmt = db
            .prepare("SELECT id,name FROM actors WHERE kind='human' ORDER BY name")
            .map_err(db_error)?;
        let people = stmt
            .query_map([], |r| {
                Ok(json!({"id": r.get::<_, String>(0)?, "name": r.get::<_, String>(1)?}))
            })
            .map_err(db_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(db_error)?;
        body["people"] = json!(people);
    }
    Ok(Json(body))
}

/// Generates a new setup code (only before setup) and returns it for the
/// operator to read from the node's console.
pub fn new_setup_code(db: &Connection) -> rusqlite::Result<Option<String>> {
    if role(db)?.is_some() {
        return Ok(None);
    }
    let code = human_code();
    set_meta(db, "setup-code-hash", &hex::encode(code_hash(&code)))?;
    set_meta(db, "setup-failures", "0")?;
    Ok(Some(code))
}

#[derive(Deserialize)]
pub struct Setup {
    code: String,
    company: String,
    /// A seeded person to become, or `name` for someone new.
    actor: Option<String>,
    name: Option<String>,
    username: String,
    password: String,
    #[serde(flatten)]
    device: Device,
}

fn new_actor_id(tx: &Connection, name: &str) -> Result<String, ApiError> {
    let base: String = name
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(16)
        .collect();
    let base = if base.is_empty() {
        "person".to_string()
    } else {
        base
    };
    for n in 0..1000 {
        let id = if n == 0 {
            base.clone()
        } else {
            format!("{base}{n}")
        };
        let taken: bool = tx
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1)",
                [&id],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        if !taken {
            return Ok(id);
        }
    }
    Err(err(StatusCode::CONFLICT, "could not allocate a person ID"))
}

pub async fn setup(
    State(state): State<Db>,
    Json(body): Json<Setup>,
) -> Result<Json<SignedIn>, ApiError> {
    let username = body.username.trim().to_lowercase();
    if !valid_username(&username) {
        return Err(err(
            StatusCode::BAD_REQUEST,
            "username must be 3-32 lowercase letters, digits, . _ -",
        ));
    }
    check_password(&body.password)?;
    let company = clean_label(&body.company, 80);
    if company.is_empty() {
        return Err(err(StatusCode::BAD_REQUEST, "company name required"));
    }
    let password = body.password.clone();
    let password_hash = blocking(move || hash_password(&password)).await;
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    if role(&tx).map_err(db_error)?.is_some() {
        return Err(err(StatusCode::CONFLICT, "workspace is already set up"));
    }
    let failures: i64 = meta(&tx, "setup-failures")
        .map_err(db_error)?
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    if failures >= LOCK_AFTER {
        return Err(err(
            StatusCode::TOO_MANY_REQUESTS,
            "too many wrong setup codes; restart the node for a new code",
        ));
    }
    let expected = meta(&tx, "setup-code-hash").map_err(db_error)?;
    if expected.as_deref() != Some(hex::encode(code_hash(&body.code)).as_str()) {
        set_meta(&tx, "setup-failures", &(failures + 1).to_string()).map_err(db_error)?;
        tx.commit().map_err(db_error)?;
        return Err(err(StatusCode::FORBIDDEN, "wrong setup code"));
    }
    let actor = match (body.actor.as_deref(), body.name.as_deref()) {
        (Some(id), _) => {
            let human: bool = tx
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1 AND kind='human')",
                    [id],
                    |r| r.get(0),
                )
                .map_err(db_error)?;
            if !human {
                return Err(err(StatusCode::BAD_REQUEST, "unknown person"));
            }
            id.to_string()
        }
        (None, Some(name)) if !clean_label(name, 80).is_empty() => {
            let name = clean_label(name, 80);
            let id = new_actor_id(&tx, &name)?;
            tx.execute(
                "INSERT INTO actors VALUES (?1,'human',?2)",
                params![id, name],
            )
            .map_err(db_error)?;
            id
        }
        _ => {
            return Err(err(
                StatusCode::BAD_REQUEST,
                "choose a person or enter a name",
            ))
        }
    };
    let key = SigningKey::generate(&mut OsRng);
    let authority: String = meta(&tx, "authority-id-v1")
        .map_err(db_error)?
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    set_meta(&tx, "identity-signing-key", &hex::encode(key.to_bytes())).map_err(db_error)?;
    set_meta(
        &tx,
        "identity-public-key",
        &hex::encode(key.verifying_key().to_bytes()),
    )
    .map_err(db_error)?;
    set_meta(&tx, "workspace-id", &authority).map_err(db_error)?;
    set_meta(&tx, "workspace-name", &company).map_err(db_error)?;
    set_meta(&tx, "identity-role", "master").map_err(db_error)?;
    tx.execute(
        "DELETE FROM metadata WHERE key IN ('setup-code-hash','setup-failures')",
        [],
    )
    .map_err(db_error)?;
    tx.execute(
        "INSERT INTO accounts(actor,username,password_hash,created) VALUES (?1,?2,?3,?4)",
        params![actor, username, password_hash, now()],
    )
    .map_err(db_error)?;
    tx.execute(
        "INSERT OR IGNORE INTO actor_roles VALUES (?1,'org-admin')",
        [&actor],
    )
    .map_err(db_error)?;
    audit(&tx, &actor, &company, "workspace_setup").map_err(db_error)?;
    let result = open_session(&tx, &actor, &body.device)?;
    tx.commit().map_err(db_error)?;
    Ok(Json(result))
}

// ------------------------------------------------------------------ sign-in --

#[derive(Deserialize)]
pub struct Login {
    username: String,
    password: String,
    #[serde(flatten)]
    device: Device,
}

pub async fn login(
    State(state): State<Db>,
    Json(body): Json<Login>,
) -> Result<Json<SignedIn>, ApiError> {
    let username = body.username.trim().to_lowercase();
    let account: Option<(String, Option<String>, i64)> = {
        let db = state.lock().unwrap();
        require_master(&db)?;
        db.query_row(
            "SELECT actor,password_hash,locked_until FROM accounts WHERE username=?1",
            [&username],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(db_error)?
    };
    if let Some((_, _, locked)) = &account {
        if *locked > now() {
            return Err(err(
                StatusCode::TOO_MANY_REQUESTS,
                "too many failed sign-ins; try again later",
            ));
        }
    }
    let stored = account
        .as_ref()
        .and_then(|a| a.1.clone())
        .unwrap_or_else(|| dummy_hash().to_string());
    let password = body.password.clone();
    let ok = blocking(move || verify_password(&password, &stored)).await;
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let Some((actor, Some(_), _)) = account else {
        return Err(err(StatusCode::UNAUTHORIZED, "wrong username or password"));
    };
    if !ok {
        let failures: i64 = tx
            .query_row(
                "UPDATE accounts SET failures=failures+1 WHERE actor=?1 RETURNING failures",
                [&actor],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        if failures >= LOCK_AFTER {
            let lock = (LOCK_SECONDS << (failures - LOCK_AFTER).min(10)).min(MAX_LOCK_SECONDS);
            tx.execute(
                "UPDATE accounts SET locked_until=?2 WHERE actor=?1",
                params![actor, now() + lock],
            )
            .map_err(db_error)?;
        }
        audit(&tx, &actor, &actor, "sign_in_failed").map_err(db_error)?;
        tx.commit().map_err(db_error)?;
        return Err(err(StatusCode::UNAUTHORIZED, "wrong username or password"));
    }
    let disabled: bool = tx
        .query_row(
            "SELECT disabled FROM accounts WHERE actor=?1",
            [&actor],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if disabled {
        return Err(err(StatusCode::FORBIDDEN, "account disabled"));
    }
    tx.execute(
        "UPDATE accounts SET failures=0, locked_until=0 WHERE actor=?1",
        [&actor],
    )
    .map_err(db_error)?;
    let result = open_session(&tx, &actor, &body.device)?;
    tx.commit().map_err(db_error)?;
    Ok(Json(result))
}

#[derive(Deserialize)]
pub struct Refresh {
    refresh_token: String,
}

/// Rotates the refresh token. Presenting a refresh token that was already
/// rotated means it was copied: the whole session is revoked.
pub async fn refresh(
    State(state): State<Db>,
    Json(body): Json<Refresh>,
) -> Result<Json<SignedIn>, ApiError> {
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    require_master(&tx)?;
    let presented = hash(&body.refresh_token);
    let current: Option<(String, String, i64, bool)> = tx
        .query_row(
            "SELECT id,actor,refresh_expires,revoked FROM sessions WHERE refresh_hash=?1",
            [&presented],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()
        .map_err(db_error)?;
    let invalid = err(StatusCode::UNAUTHORIZED, "session ended; sign in again");
    let Some((id, actor, expires, revoked)) = current else {
        let reused: Option<(String, String)> = tx
            .query_row(
                "SELECT id,actor FROM sessions WHERE previous_refresh_hash=?1",
                [&presented],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(db_error)?;
        if let Some((id, actor)) = reused {
            revoke_session(&tx, &id, &actor, "refresh_reuse")?;
            tx.commit().map_err(db_error)?;
        }
        return Err(invalid);
    };
    let disabled: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE actor=?1 AND disabled=1)",
            [&actor],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if revoked || disabled || expires <= now() {
        return Err(invalid);
    }
    let next = secret();
    tx.execute(
        "UPDATE sessions SET previous_refresh_hash=refresh_hash, refresh_hash=?2, refresh_expires=?3, last_seen=?4 WHERE id=?1",
        params![id, hash(&next), now() + REFRESH_SECONDS, now()],
    )
    .map_err(db_error)?;
    let result = signed_in(&tx, &actor, &id, next)?;
    tx.commit().map_err(db_error)?;
    Ok(Json(result))
}

pub async fn logout(State(state): State<Db>, headers: HeaderMap) -> Result<StatusCode, ApiError> {
    let mut db = state.lock().unwrap();
    let tx = db.transaction().map_err(db_error)?;
    require_master(&tx)?;
    let claims = session_claims(&tx, &headers)?;
    revoke_session(&tx, &claims.sid, &claims.sub, "signed_out")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct InviteAccept {
    code: String,
    username: Option<String>,
    password: String,
    #[serde(flatten)]
    device: Device,
}

/// Redeems an invitation (creates the account) or a reset code (sets a new
/// password and ends every existing session).
pub async fn accept_invite(
    State(state): State<Db>,
    Json(body): Json<InviteAccept>,
) -> Result<Json<SignedIn>, ApiError> {
    check_password(&body.password)?;
    let password = body.password.clone();
    let password_hash = blocking(move || hash_password(&password)).await;
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    require_master(&tx)?;
    let invite: Option<(String, String)> = tx
        .query_row(
            "SELECT actor,purpose FROM invites WHERE code_hash=?1 AND used IS NULL AND expires>?2",
            params![code_hash(&body.code), now()],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (actor, purpose) = invite.ok_or(err(
        StatusCode::FORBIDDEN,
        "invitation code is invalid, used or expired",
    ))?;
    if purpose == "invite" {
        let username = body
            .username
            .as_deref()
            .unwrap_or_default()
            .trim()
            .to_lowercase();
        if !valid_username(&username) {
            return Err(err(
                StatusCode::BAD_REQUEST,
                "username must be 3-32 lowercase letters, digits, . _ -",
            ));
        }
        let taken: bool = tx
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM accounts WHERE username=?1)",
                [&username],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        if taken {
            return Err(err(StatusCode::CONFLICT, "username already taken"));
        }
        tx.execute(
            "INSERT INTO accounts(actor,username,password_hash,created) VALUES (?1,?2,?3,?4)",
            params![actor, username, password_hash, now()],
        )
        .map_err(db_error)?;
        audit(&tx, &actor, &actor, "account_created").map_err(db_error)?;
    } else {
        tx.execute(
            "UPDATE accounts SET password_hash=?2, failures=0, locked_until=0 WHERE actor=?1",
            params![actor, password_hash],
        )
        .map_err(db_error)?;
        revoke_all(&tx, &actor, None, &actor, "password_reset")?;
        audit(&tx, &actor, &actor, "password_reset").map_err(db_error)?;
    }
    tx.execute(
        "UPDATE invites SET used=?2 WHERE code_hash=?1",
        params![code_hash(&body.code), now()],
    )
    .map_err(db_error)?;
    let result = open_session(&tx, &actor, &body.device)?;
    tx.commit().map_err(db_error)?;
    Ok(Json(result))
}

#[derive(Deserialize)]
pub struct PasswordChange {
    current: String,
    new: String,
}

/// Changes the password and signs out every other session.
pub async fn change_password(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(body): Json<PasswordChange>,
) -> Result<StatusCode, ApiError> {
    check_password(&body.new)?;
    let (claims, stored) = {
        let db = state.lock().unwrap();
        require_master(&db)?;
        let claims = session_claims(&db, &headers)?;
        let stored: Option<String> = db
            .query_row(
                "SELECT password_hash FROM accounts WHERE actor=?1",
                [&claims.sub],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        (claims, stored.unwrap_or_else(|| dummy_hash().to_string()))
    };
    let (current, new) = (body.current.clone(), body.new.clone());
    let (ok, new_hash) =
        blocking(move || (verify_password(&current, &stored), hash_password(&new))).await;
    if !ok {
        return Err(err(StatusCode::FORBIDDEN, "current password is wrong"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    tx.execute(
        "UPDATE accounts SET password_hash=?2 WHERE actor=?1",
        params![claims.sub, new_hash],
    )
    .map_err(db_error)?;
    revoke_all(
        &tx,
        &claims.sub,
        Some(&claims.sid),
        &claims.sub,
        "password_changed",
    )?;
    audit(&tx, &claims.sub, &claims.sub, "password_changed").map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::NO_CONTENT)
}

fn session_rows(
    db: &Connection,
    actor: Option<&str>,
    current: &str,
) -> Result<Vec<Value>, ApiError> {
    let mut stmt = db
        .prepare(
            "SELECT s.id,s.actor,a.name,s.device,s.platform,s.created,s.last_seen FROM sessions s JOIN actors a ON a.id=s.actor
             WHERE s.revoked=0 AND s.refresh_expires>?1 AND (?2 IS NULL OR s.actor=?2) ORDER BY s.last_seen DESC",
        )
        .map_err(db_error)?;
    let rows = stmt
        .query_map(params![now(), actor], |r| {
            let id: String = r.get(0)?;
            Ok(json!({
                "id": id, "actor": r.get::<_, String>(1)?, "name": r.get::<_, String>(2)?,
                "device": r.get::<_, String>(3)?, "platform": r.get::<_, String>(4)?,
                "created": r.get::<_, i64>(5)?, "last_seen": r.get::<_, i64>(6)?,
                "current": id == current,
            }))
        })
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    Ok(rows)
}

/// This person's signed-in devices.
pub async fn sessions(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let db = state.lock().unwrap();
    require_master(&db)?;
    let claims = session_claims(&db, &headers)?;
    Ok(Json(json!(session_rows(
        &db,
        Some(&claims.sub),
        &claims.sid
    )?)))
}

/// Ends a session: your own, or anyone's for an organization admin.
pub async fn revoke(
    State(state): State<Db>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    require_master(&tx)?;
    let claims = session_claims(&tx, &headers)?;
    let owner: Option<String> = tx
        .query_row("SELECT actor FROM sessions WHERE id=?1", [&id], |r| {
            r.get(0)
        })
        .optional()
        .map_err(db_error)?;
    let owner = owner.ok_or(err(StatusCode::NOT_FOUND, "session not found"))?;
    if owner != claims.sub && !is_admin(&tx, &claims.sub)? {
        return Err(err(StatusCode::FORBIDDEN, "not your session"));
    }
    revoke_session(&tx, &id, &claims.sub, "revoked")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::NO_CONTENT)
}

// -------------------------------------------------------------------- admin --

/// People, their account state and devices, for organization admins.
pub async fn people(State(state): State<Db>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let db = state.lock().unwrap();
    require_master(&db)?;
    let claims = require_admin(&db, &headers)?;
    let mut stmt = db
        .prepare(
            "SELECT a.id,a.name,c.username,COALESCE(c.disabled,0),
                    (SELECT COUNT(*) FROM sessions s WHERE s.actor=a.id AND s.revoked=0 AND s.refresh_expires>?1),
                    EXISTS(SELECT 1 FROM invites i WHERE i.actor=a.id AND i.used IS NULL AND i.expires>?1),
                    EXISTS(SELECT 1 FROM actor_roles r WHERE r.actor=a.id AND r.role='org-admin')
             FROM actors a LEFT JOIN accounts c ON c.actor=a.id WHERE a.kind='human' ORDER BY a.name",
        )
        .map_err(db_error)?;
    let people = stmt
        .query_map([now()], |r| {
            Ok(json!({
                "id": r.get::<_, String>(0)?, "name": r.get::<_, String>(1)?,
                "username": r.get::<_, Option<String>>(2)?, "disabled": r.get::<_, bool>(3)?,
                "sessions": r.get::<_, i64>(4)?, "invite_pending": r.get::<_, bool>(5)?,
                "admin": r.get::<_, bool>(6)?,
            }))
        })
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    let devices = session_rows(&db, None, &claims.sid)?;
    Ok(Json(json!({"people": people, "sessions": devices})))
}

#[derive(Deserialize)]
pub struct InviteRequest {
    actor: Option<String>,
    name: Option<String>,
}

fn create_invite(tx: &Transaction<'_>, actor: &str, by: &str) -> Result<Value, ApiError> {
    let has_account: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE actor=?1)",
            [actor],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    let purpose = if has_account { "reset" } else { "invite" };
    // A new code replaces any unused one for the same person.
    tx.execute(
        "UPDATE invites SET used=?2 WHERE actor=?1 AND used IS NULL",
        params![actor, now()],
    )
    .map_err(db_error)?;
    let code = human_code();
    let expires = now() + INVITE_SECONDS;
    tx.execute(
        "INSERT INTO invites(code_hash,actor,purpose,created_by,created,expires) VALUES (?1,?2,?3,?4,?5,?6)",
        params![code_hash(&code), actor, purpose, by, now(), expires],
    )
    .map_err(db_error)?;
    audit(tx, by, actor, &format!("{purpose}_issued")).map_err(db_error)?;
    Ok(json!({"code": code, "actor": actor, "purpose": purpose, "expires": expires}))
}

/// Issues a one-time code: an invitation for someone without an account
/// (optionally creating the person), or a password reset for someone with one.
pub async fn invite(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(body): Json<InviteRequest>,
) -> Result<Json<Value>, ApiError> {
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    require_master(&tx)?;
    let claims = require_admin(&tx, &headers)?;
    let actor = match (body.actor.as_deref(), body.name.as_deref()) {
        (Some(id), _) => {
            let human: bool = tx
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1 AND kind='human')",
                    [id],
                    |r| r.get(0),
                )
                .map_err(db_error)?;
            if !human {
                return Err(err(StatusCode::NOT_FOUND, "unknown person"));
            }
            id.to_string()
        }
        (None, Some(name)) if !clean_label(name, 80).is_empty() => {
            let name = clean_label(name, 80);
            let id = new_actor_id(&tx, &name)?;
            tx.execute(
                "INSERT INTO actors VALUES (?1,'human',?2)",
                params![id, name],
            )
            .map_err(db_error)?;
            audit(&tx, &claims.sub, &id, "person_added").map_err(db_error)?;
            id
        }
        _ => {
            return Err(err(
                StatusCode::BAD_REQUEST,
                "choose a person or enter a name",
            ))
        }
    };
    let result = create_invite(&tx, &actor, &claims.sub)?;
    tx.commit().map_err(db_error)?;
    Ok(Json(result))
}

/// Local-operator recovery (`office-node account-code ACTOR`): prints an
/// invitation or reset code without signing in.
pub fn operator_code(
    db: &mut Connection,
    actor: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if role(&tx)? != Some(Role::Master) {
        return Err("account codes are issued by the master node".into());
    }
    let human: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1 AND kind='human')",
        [actor],
        |r| r.get(0),
    )?;
    if !human {
        return Err("unknown human actor".into());
    }
    let result = create_invite(&tx, actor, "local-operator").map_err(|(_, m)| m)?;
    tx.commit()?;
    Ok(result)
}

#[derive(Deserialize)]
pub struct AccountState {
    disabled: bool,
}

/// Disables (and signs out) or re-enables someone. Admins cannot disable
/// themselves, so the workspace keeps an admin.
pub async fn set_disabled(
    State(state): State<Db>,
    headers: HeaderMap,
    Path(actor): Path<String>,
    Json(body): Json<AccountState>,
) -> Result<StatusCode, ApiError> {
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    require_master(&tx)?;
    let claims = require_admin(&tx, &headers)?;
    if actor == claims.sub && body.disabled {
        return Err(err(
            StatusCode::CONFLICT,
            "you cannot disable your own account",
        ));
    }
    let changed = tx
        .execute(
            "UPDATE accounts SET disabled=?2 WHERE actor=?1",
            params![actor, body.disabled],
        )
        .map_err(db_error)?;
    if changed == 0 {
        return Err(err(StatusCode::NOT_FOUND, "no account for this person"));
    }
    if body.disabled {
        revoke_all(&tx, &actor, None, &claims.sub, "account_disabled")?;
    }
    bump_realtime_epoch(&tx).map_err(db_error)?;
    audit(
        &tx,
        &claims.sub,
        &actor,
        if body.disabled {
            "account_disabled"
        } else {
            "account_enabled"
        },
    )
    .map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct Rename {
    name: String,
}
pub async fn rename(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(body): Json<Rename>,
) -> Result<StatusCode, ApiError> {
    let name = clean_label(&body.name, 80);
    if name.is_empty() {
        return Err(err(StatusCode::BAD_REQUEST, "company name required"));
    }
    let mut db = state.lock().unwrap();
    let tx = db.transaction().map_err(db_error)?;
    require_master(&tx)?;
    let claims = require_admin(&tx, &headers)?;
    set_meta(&tx, "workspace-name", &name).map_err(db_error)?;
    audit(&tx, &claims.sub, &name, "workspace_renamed").map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::NO_CONTENT)
}

// ------------------------------------------------------------ federation --

pub async fn nodes(State(state): State<Db>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let db = state.lock().unwrap();
    require_master(&db)?;
    require_admin(&db, &headers)?;
    let mut stmt = db
        .prepare("SELECT id,name,created,joined,last_sync,revoked,join_expires FROM identity_nodes ORDER BY created")
        .map_err(db_error)?;
    let rows = stmt
        .query_map([], |r| {
            Ok(json!({
                "id": r.get::<_, String>(0)?, "name": r.get::<_, String>(1)?,
                "created": r.get::<_, i64>(2)?, "joined": r.get::<_, Option<i64>>(3)?,
                "last_sync": r.get::<_, Option<i64>>(4)?, "revoked": r.get::<_, bool>(5)?,
                "join_expires": r.get::<_, i64>(6)?,
            }))
        })
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    Ok(Json(json!(rows)))
}

/// Creates a one-hour code another node uses to join this workspace.
pub async fn add_node(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(body): Json<Rename>,
) -> Result<Json<Value>, ApiError> {
    let name = clean_label(&body.name, 60);
    if name.is_empty() {
        return Err(err(StatusCode::BAD_REQUEST, "node name required"));
    }
    let mut db = state.lock().unwrap();
    let tx = db.transaction().map_err(db_error)?;
    require_master(&tx)?;
    let claims = require_admin(&tx, &headers)?;
    let id = uuid::Uuid::new_v4().to_string();
    let code = human_code();
    let expires = now() + NODE_CODE_SECONDS;
    tx.execute(
        "INSERT INTO identity_nodes(id,name,join_code_hash,join_expires,created) VALUES (?1,?2,?3,?4,?5)",
        params![id, name, code_hash(&code), expires, now()],
    )
    .map_err(db_error)?;
    audit(&tx, &claims.sub, &id, "node_join_code_issued").map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    Ok(Json(
        json!({"id": id, "name": name, "code": code, "expires": expires}),
    ))
}

pub async fn revoke_node(
    State(state): State<Db>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<StatusCode, ApiError> {
    let mut db = state.lock().unwrap();
    let tx = db.transaction().map_err(db_error)?;
    require_master(&tx)?;
    let claims = require_admin(&tx, &headers)?;
    let changed = tx
        .execute("UPDATE identity_nodes SET revoked=1, credential_hash=NULL, join_code_hash=NULL WHERE id=?1", [&id])
        .map_err(db_error)?;
    if changed == 0 {
        return Err(err(StatusCode::NOT_FOUND, "node not found"));
    }
    audit(&tx, &claims.sub, &id, "node_revoked").map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct Join {
    code: String,
}

/// A member node redeems its join code for a node credential.
pub async fn join(
    State(state): State<Db>,
    Json(body): Json<Join>,
) -> Result<Json<Value>, ApiError> {
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    require_master(&tx)?;
    let id: Option<String> = tx
        .query_row(
            "SELECT id FROM identity_nodes WHERE join_code_hash=?1 AND join_expires>?2 AND joined IS NULL AND revoked=0",
            params![code_hash(&body.code), now()],
            |r| r.get(0),
        )
        .optional()
        .map_err(db_error)?;
    let id = id.ok_or(err(
        StatusCode::FORBIDDEN,
        "join code is invalid, used or expired",
    ))?;
    let credential = secret();
    tx.execute(
        "UPDATE identity_nodes SET credential_hash=?2, join_code_hash=NULL, joined=?3 WHERE id=?1",
        params![id, hash(&credential), now()],
    )
    .map_err(db_error)?;
    audit(&tx, "node", &id, "node_joined").map_err(db_error)?;
    let public = meta(&tx, "identity-public-key").map_err(db_error)?;
    let workspace = workspace_json(&tx)?;
    tx.commit().map_err(db_error)?;
    Ok(Json(
        json!({"node": id, "credential": credential, "public_key": public, "workspace": workspace}),
    ))
}

/// What a member node needs to check access tokens: the key, people,
/// account states and sessions revoked recently enough that their access
/// tokens may still be unexpired.
pub async fn directory(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let mut db = state.lock().unwrap();
    let tx = db.transaction().map_err(db_error)?;
    require_master(&tx)?;
    let credential =
        bearer(&headers).ok_or(err(StatusCode::UNAUTHORIZED, "node credential required"))?;
    let changed = tx
        .execute(
            "UPDATE identity_nodes SET last_sync=?2 WHERE credential_hash=?1 AND revoked=0",
            params![hash(credential), now()],
        )
        .map_err(db_error)?;
    if changed == 0 {
        return Err(err(
            StatusCode::UNAUTHORIZED,
            "node credential invalid or revoked",
        ));
    }
    let people: Vec<Value> = {
        let mut stmt = tx
            .prepare("SELECT a.id,a.name,c.username,COALESCE(c.disabled,0) FROM actors a LEFT JOIN accounts c ON c.actor=a.id WHERE a.kind='human'")
            .map_err(db_error)?;
        let rows = stmt
            .query_map([], |r| {
                Ok(
                    json!({"id": r.get::<_, String>(0)?, "name": r.get::<_, String>(1)?,
                    "username": r.get::<_, Option<String>>(2)?, "disabled": r.get::<_, bool>(3)?}),
                )
            })
            .map_err(db_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(db_error)?;
        rows
    };
    let revoked: Vec<Value> = {
        let mut stmt = tx
            .prepare("SELECT id,actor FROM sessions WHERE revoked=1 AND revoked_at>?1")
            .map_err(db_error)?;
        let rows = stmt
            .query_map([now() - 2 * ACCESS_SECONDS], |r| {
                Ok(json!({"id": r.get::<_, String>(0)?, "actor": r.get::<_, String>(1)?}))
            })
            .map_err(db_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(db_error)?;
        rows
    };
    let public = meta(&tx, "identity-public-key").map_err(db_error)?;
    let workspace = workspace_json(&tx)?;
    tx.commit().map_err(db_error)?;
    Ok(Json(
        json!({"workspace": workspace, "public_key": public, "people": people, "revoked_sessions": revoked}),
    ))
}

/// Applies a directory pulled from the master. Returns whether anything
/// that ends access changed, in which case realtime access is rotated.
pub fn apply_directory(db: &mut Connection, directory: &Value) -> rusqlite::Result<bool> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if let Some(name) = directory["workspace"]["name"].as_str() {
        set_meta(&tx, "workspace-name", name)?;
    }
    if let Some(key) = directory["public_key"].as_str() {
        set_meta(&tx, "identity-public-key", key)?;
    }
    let mut ended = false;
    for person in directory["people"].as_array().into_iter().flatten() {
        let (Some(id), Some(name)) = (person["id"].as_str(), person["name"].as_str()) else {
            continue;
        };
        tx.execute(
            "INSERT OR IGNORE INTO actors VALUES (?1,'human',?2)",
            params![id, name],
        )?;
        if let Some(username) = person["username"].as_str() {
            let disabled = person["disabled"].as_bool().unwrap_or(false);
            let before: Option<bool> = tx
                .query_row("SELECT disabled FROM accounts WHERE actor=?1", [id], |r| {
                    r.get(0)
                })
                .optional()?;
            tx.execute(
                "INSERT INTO accounts(actor,username,password_hash,created,disabled) VALUES (?1,?2,NULL,?3,?4)
                 ON CONFLICT(actor) DO UPDATE SET username=excluded.username, disabled=excluded.disabled",
                params![id, username, now(), disabled],
            )?;
            ended |= disabled && before != Some(true);
        }
    }
    for session in directory["revoked_sessions"]
        .as_array()
        .into_iter()
        .flatten()
    {
        let (Some(id), Some(actor)) = (session["id"].as_str(), session["actor"].as_str()) else {
            continue;
        };
        let changed = tx.execute(
            "INSERT INTO sessions(id,actor,device,platform,created,last_seen,refresh_expires,revoked,revoked_at,revoked_reason)
             SELECT ?1,?2,'','',?3,?3,0,1,?3,'master' WHERE EXISTS(SELECT 1 FROM actors WHERE id=?2)
             ON CONFLICT(id) DO UPDATE SET revoked=1 WHERE revoked=0",
            params![id, actor, now()],
        )?;
        ended |= changed > 0;
    }
    set_meta(&tx, "identity-synced", &now().to_string())?;
    if ended {
        bump_realtime_epoch(&tx)?;
    }
    tx.commit()?;
    Ok(ended)
}

/// Loopback address of the master from its URL (`http://127.0.0.1:PORT`).
/// Remote masters are reached through an SSH tunnel; plaintext HTTP never
/// leaves the machine.
pub fn master_address(url: &str) -> Option<std::net::SocketAddr> {
    let rest = url.strip_prefix("http://")?.trim_end_matches('/');
    let address: std::net::SocketAddr = rest.parse().ok()?;
    address.ip().is_loopback().then_some(address)
}

async fn master_request(
    address: std::net::SocketAddr,
    method: &str,
    path: &str,
    authorization: Option<&str>,
    body: Option<&[u8]>,
) -> Option<(u16, Vec<u8>)> {
    // A full workspace proxy includes long-running agent chat requests.
    // Never route loopback credentials through a system HTTP proxy or redirects.
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    let client = CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("HTTP client")
    });
    let timeout = if path.starts_with("/v1/agents/") && path.ends_with("/chat") {
        65
    } else {
        5
    };
    let mut request = client
        .request(
            reqwest::Method::from_bytes(method.as_bytes()).ok()?,
            format!("http://{address}{path}"),
        )
        .header("content-type", "application/json")
        .timeout(std::time::Duration::from_secs(timeout));
    if let Some(authorization) = authorization {
        request = request.header("authorization", authorization);
    }
    if let Some(body) = body {
        request = request.body(body.to_vec());
    }
    let response = request.send().await.ok()?;
    let status = response.status().as_u16();
    Some((status, response.bytes().await.ok()?.to_vec()))
}

/// `office-node join MASTER_URL` (code on stdin): turns this node into a
/// member of the master's workspace.
pub async fn join_master(
    db: &mut Connection,
    url: &str,
    code: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    if role(db)?.is_some() {
        return Err("this node already belongs to a workspace".into());
    }
    let address = master_address(url).ok_or(
        "master URL must be http://127.0.0.1:PORT (use an SSH tunnel for another machine)",
    )?;
    let body = serde_json::to_vec(&json!({"code": code}))?;
    let (status, response) = master_request(address, "POST", "/v1/nodes/join", None, Some(&body))
        .await
        .ok_or("master node unreachable")?;
    if status != 200 {
        return Err(format!("master refused the join code ({status})").into());
    }
    let joined: Value = serde_json::from_slice(&response)?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    set_meta(&tx, "identity-role", "member")?;
    set_meta(&tx, "identity-master-url", &format!("http://{address}"))?;
    set_meta(
        &tx,
        "identity-node-id",
        joined["node"].as_str().ok_or("join response")?,
    )?;
    set_meta(
        &tx,
        "identity-node-credential",
        joined["credential"].as_str().ok_or("join response")?,
    )?;
    set_meta(
        &tx,
        "identity-public-key",
        joined["public_key"].as_str().ok_or("join response")?,
    )?;
    set_meta(
        &tx,
        "workspace-id",
        joined["workspace"]["id"].as_str().ok_or("join response")?,
    )?;
    set_meta(
        &tx,
        "workspace-name",
        joined["workspace"]["name"].as_str().unwrap_or_default(),
    )?;
    tx.execute(
        "DELETE FROM metadata WHERE key IN ('setup-code-hash','setup-failures')",
        [],
    )?;
    audit(&tx, "local-operator", url, "joined_master")?;
    tx.commit()?;
    sync_once(db)
        .await
        .map_err(|e| format!("joined, but the first directory sync failed: {e}"))?;
    Ok(())
}

async fn sync_once(db: &mut Connection) -> Result<bool, String> {
    let (url, credential) = (
        meta(db, "identity-master-url").map_err(|e| e.to_string())?,
        meta(db, "identity-node-credential").map_err(|e| e.to_string())?,
    );
    let (Some(url), Some(credential)) = (url, credential) else {
        return Err("not a member node".into());
    };
    let address = master_address(&url).ok_or("bad master URL")?;
    let (status, body) = master_request(
        address,
        "GET",
        "/v1/nodes/directory",
        Some(&format!("Bearer {credential}")),
        None,
    )
    .await
    .ok_or("master unreachable")?;
    if status != 200 {
        return Err(format!("master refused the directory request ({status})"));
    }
    let directory: Value = serde_json::from_slice(&body).map_err(|e| e.to_string())?;
    apply_directory(db, &directory).map_err(|e| e.to_string())
}

/// Member-node loop: pulls the directory every few seconds. While the master
/// is unreachable, already issued access tokens stay valid until they
/// expire (at most ACCESS_SECONDS); no new sign-ins are possible.
pub async fn sync_loop(state: Db) {
    let mut healthy = true;
    loop {
        let snapshot = {
            let db = state.lock().unwrap();
            (
                meta(&db, "identity-master-url").ok().flatten(),
                meta(&db, "identity-node-credential").ok().flatten(),
            )
        };
        let result = match snapshot {
            (Some(url), Some(credential)) => match master_address(&url) {
                Some(address) => match master_request(
                    address,
                    "GET",
                    "/v1/nodes/directory",
                    Some(&format!("Bearer {credential}")),
                    None,
                )
                .await
                {
                    Some((200, body)) => serde_json::from_slice::<Value>(&body)
                        .map_err(|e| e.to_string())
                        .and_then(|d| {
                            apply_directory(&mut state.lock().unwrap(), &d)
                                .map_err(|e| e.to_string())
                        }),
                    Some((status, _)) => Err(format!("master refused directory ({status})")),
                    None => Err("master unreachable".into()),
                },
                None => Err("bad master URL".into()),
            },
            _ => return,
        };
        match (&result, healthy) {
            (Err(e), true) => eprintln!("identity sync failing: {e}"),
            (Ok(_), false) => eprintln!("identity sync restored"),
            _ => {}
        }
        healthy = result.is_ok();
        tokio::time::sleep(std::time::Duration::from_secs(SYNC_SECONDS)).await;
    }
}

/// Account/admin requests always go to the master. In shared workspace mode,
/// all office requests (including realtime tickets and room policy) go there too. Signing out is also recorded locally at
/// once so the token stops working here before the next sync.
pub async fn forward_to_master(State(state): State<Db>, request: Request, next: Next) -> Response {
    let path = request.uri().path().to_string();
    let shared =
        std::env::var("MONASTACK_WORKSPACE_MODE").unwrap_or_else(|_| "shared".into()) == "shared";
    let forwarded = path.starts_with("/v1/auth/")
        || path.starts_with("/v1/admin/")
        || path == "/v1/setup"
        || (shared
            && path.starts_with("/v1/")
            && path != "/v1/workspace"
            && !path.starts_with("/v1/nodes/"));
    if !forwarded {
        return next.run(request).await;
    }
    let master = {
        let db = state.lock().unwrap();
        match role(&db) {
            Ok(Some(Role::Member)) => meta(&db, "identity-master-url").ok().flatten(),
            _ => None,
        }
    };
    let Some(url) = master else {
        return next.run(request).await;
    };
    let Some(address) = master_address(&url) else {
        return (StatusCode::BAD_GATEWAY, "bad master URL").into_response();
    };
    let method = request.method().as_str().to_string();
    let path_and_query = request
        .uri()
        .path_and_query()
        .map(|p| p.as_str().to_string())
        .unwrap_or(path.clone());
    let authorization = request
        .headers()
        .get("authorization")
        .and_then(|h| h.to_str().ok())
        .map(str::to_string);
    let Ok(body) = axum::body::to_bytes(request.into_body(), 1 << 20).await else {
        return (StatusCode::PAYLOAD_TOO_LARGE, "request too large").into_response();
    };
    let Some((status, response)) = master_request(
        address,
        &method,
        &path_and_query,
        authorization.as_deref(),
        (!body.is_empty()).then_some(&body[..]),
    )
    .await
    else {
        return (StatusCode::BAD_GATEWAY, "master node unreachable").into_response();
    };
    if path == "/v1/auth/logout" && (200..300).contains(&status) {
        if let Some(token) = authorization
            .as_deref()
            .and_then(|a| a.strip_prefix("Bearer "))
        {
            let db = state.lock().unwrap();
            if let Ok(claims) = claims_from_access(&db, token) {
                let _ = db.execute(
                    "INSERT INTO sessions(id,actor,device,platform,created,last_seen,refresh_expires,revoked,revoked_at,revoked_reason) VALUES (?1,?2,'','',?3,?3,0,1,?3,'signed_out') ON CONFLICT(id) DO UPDATE SET revoked=1",
                    params![claims.sid, claims.sub, now()],
                );
                let _ = db.execute(
                    "INSERT INTO metadata(key,value) VALUES ('realtime_epoch','1') ON CONFLICT(key) DO UPDATE SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT)",
                    [],
                );
            }
        }
    }
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(Body::from(response))
        .unwrap_or_else(|_| StatusCode::BAD_GATEWAY.into_response())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn access_tokens_verify_expire_and_reject_tampering() {
        let key = SigningKey::generate(&mut OsRng);
        let claims = Claims {
            v: 1,
            iss: "w".into(),
            sub: "an".into(),
            sid: "s".into(),
            iat: 1000,
            exp: 1600,
        };
        let token = sign_access(&key, &claims);
        assert_eq!(
            verify_access(&key.verifying_key(), &token, 1100),
            Some(claims.clone())
        );
        assert_eq!(
            verify_access(&key.verifying_key(), &token, 1600),
            None,
            "expired"
        );
        let other = SigningKey::generate(&mut OsRng);
        assert_eq!(
            verify_access(&other.verifying_key(), &token, 1100),
            None,
            "other key"
        );
        let (head, sig) = token.rsplit_once('.').unwrap();
        let forged_payload = b64(serde_json::to_vec(&Claims {
            sub: "van".into(),
            ..claims
        })
        .unwrap());
        let forged = format!("v1.{forged_payload}.{sig}");
        assert_eq!(
            verify_access(&key.verifying_key(), &forged, 1100),
            None,
            "changed claims"
        );
        assert!(head.starts_with("v1."));
    }

    #[test]
    fn passwords_hash_with_salt_and_verify() {
        let a = hash_password("correct horse battery");
        let b = hash_password("correct horse battery");
        assert_ne!(a, b, "salted");
        assert!(a.starts_with("$argon2id$"));
        assert!(verify_password("correct horse battery", &a));
        assert!(!verify_password("correct horse batterz", &a));
        assert!(!verify_password("anything", "not a hash"));
    }

    #[test]
    fn codes_are_grouped_and_normalised() {
        let code = human_code();
        assert_eq!(code.len(), 19);
        assert_eq!(code.matches('-').count(), 3);
        assert_eq!(
            code_hash(&code),
            code_hash(&code.to_lowercase().replace('-', " "))
        );
        assert_ne!(human_code(), code);
    }

    #[test]
    fn usernames_and_master_addresses_are_restricted() {
        assert!(valid_username("an.nguyen"));
        assert!(!valid_username("An"));
        assert!(!valid_username("a b"));
        assert!(master_address("http://127.0.0.1:47830").is_some());
        assert!(
            master_address("http://192.168.1.4:47830").is_none(),
            "no plaintext over the LAN"
        );
        assert!(master_address("https://127.0.0.1:47830").is_none());
    }
}
