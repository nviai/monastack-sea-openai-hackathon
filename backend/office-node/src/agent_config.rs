//! Persistent agent configuration and an executable, server-enforced capability catalog.
use super::{actor, db_error, err, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub const IDS: &[&str] = &[
    "mona",
    "dev-agent",
    "qa-agent",
    "pm-agent",
    "sales-agent",
    "cskh-agent",
];
pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS agent_configuration(agent TEXT PRIMARY KEY REFERENCES actors(id),config TEXT NOT NULL,version INTEGER NOT NULL DEFAULT 1,updated_by TEXT NOT NULL,updated INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS agent_configuration_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT,agent TEXT NOT NULL,actor TEXT NOT NULL,source TEXT NOT NULL,version INTEGER NOT NULL,before_json TEXT NOT NULL,after_json TEXT NOT NULL,created INTEGER NOT NULL);")
}
/// Rename only original seeded labels; preserve administrator-selected names.
fn seed_names(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    let applied: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='seed-agent-names-v1')",
        [],
        |r| r.get(0),
    )?;
    if applied {
        return Ok(());
    }
    for (id, old, name) in [
        ("dev-agent", "Dev Agent", "Atlas"),
        ("qa-agent", "QA Agent", "Iris"),
        ("pm-agent", "PM Agent", "Nova"),
        ("sales-agent", "Sales Agent", "Leo"),
        ("cskh-agent", "Customer Support Agent", "Luna"),
    ] {
        tx.execute(
            "UPDATE actors SET name=?3 WHERE id=?1 AND name=?2",
            params![id, old, name],
        )?;
        let prior: Option<(String, i64)> = tx
            .query_row(
                "SELECT config,version FROM agent_configuration WHERE agent=?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((before, version)) = prior {
            let mut value: Value = serde_json::from_str(&before).map_err(|e| {
                rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Text,
                    Box::new(e),
                )
            })?;
            if value["display_name"] != old {
                continue;
            }
            value["display_name"] = json!(name);
            let after = value.to_string();
            tx.execute("UPDATE agent_configuration SET config=?2,version=?3,updated_by='seed',updated=?4 WHERE agent=?1", params![id, after, version+1, now()])?;
            tx.execute("INSERT INTO agent_configuration_audit(agent,actor,source,version,before_json,after_json,created) VALUES (?1,'seed','seed',?2,?3,?4,?5)", params![id, version+1, before, after, now()])?;
        }
    }
    tx.execute(
        "INSERT INTO metadata VALUES ('seed-agent-names-v1','applied')",
        [],
    )?;
    Ok(())
}
/// Persist complete presets once, retaining explicit administrator customization.
pub fn seed(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    seed_names(tx)?;
    seed_english_language(tx)?;
    let applied: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='seed-agent-presets-v1')",
        [],
        |r| r.get(0),
    )?;
    if applied {
        return seed_entry_greeting(tx);
    }
    for id in IDS {
        let prior: Option<(String, i64)> = tx
            .query_row(
                "SELECT config,version FROM agent_configuration WHERE agent=?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let preset = defaults(id);
        let (before, after, version) = if let Some((raw, version)) = prior {
            let mut config: Value = serde_json::from_str(&raw).map_err(|e| {
                rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Text,
                    Box::new(e),
                )
            })?;
            if config["gender"] != "unspecified" {
                continue;
            }
            config["gender"] = json!(preset.gender);
            config["voice"] = json!(preset.voice);
            (raw, config.to_string(), version + 1)
        } else {
            ("null".into(), serde_json::to_string(&preset).unwrap(), 1)
        };
        tx.execute("INSERT INTO agent_configuration VALUES (?1,?2,?3,'seed',?4) ON CONFLICT(agent) DO UPDATE SET config=excluded.config,version=excluded.version,updated_by=excluded.updated_by,updated=excluded.updated", params![id, after, version, now()])?;
        tx.execute("INSERT INTO agent_configuration_audit(agent,actor,source,version,before_json,after_json,created) VALUES (?1,'seed','seed',?2,?3,?4,?5)", params![id, version, before, after, now()])?;
    }
    tx.execute(
        "INSERT INTO metadata VALUES ('seed-agent-presets-v1','applied')",
        [],
    )?;
    seed_entry_greeting(tx)
}
/// One-time workspace default; later explicit language choices remain configurable.
fn seed_english_language(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    let applied: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='agent-english-default-v1')",
        [],
        |r| r.get(0),
    )?;
    if applied {
        return Ok(());
    }
    for id in IDS {
        let row: Option<(String, i64)> = tx
            .query_row(
                "SELECT config,version FROM agent_configuration WHERE agent=?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((before, version)) = row {
            let mut cfg: Value = serde_json::from_str(&before).map_err(|e| {
                rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Text,
                    Box::new(e),
                )
            })?;
            if cfg["language"] == "en" {
                continue;
            }
            cfg["language"] = json!("en");
            let after = cfg.to_string();
            tx.execute("UPDATE agent_configuration SET config=?2,version=?3,updated_by='seed',updated=?4 WHERE agent=?1",params![id,after,version+1,now()])?;
            tx.execute("INSERT INTO agent_configuration_audit(agent,actor,source,version,before_json,after_json,created) VALUES (?1,'seed','english-default',?2,?3,?4,?5)",params![id,version+1,before,after,now()])?;
        }
    }
    tx.execute(
        "INSERT INTO metadata VALUES ('agent-english-default-v1','applied')",
        [],
    )?;
    Ok(())
}
/// Apply the requested new entry policy once; subsequent admin choices persist.
fn seed_entry_greeting(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    let applied: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='agent-entry-greeting-v1')",
        [],
        |r| r.get(0),
    )?;
    if applied {
        return Ok(());
    }
    for id in IDS {
        let row: Option<(String, i64)> = tx
            .query_row(
                "SELECT config,version FROM agent_configuration WHERE agent=?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((before, version)) = row {
            let mut config: Value = serde_json::from_str(&before).map_err(|e| {
                rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Text,
                    Box::new(e),
                )
            })?;
            if config["activation_mode"] == "automatic" && config["greeting"] == true {
                continue;
            }
            config["activation_mode"] = json!("automatic");
            config["greeting"] = json!(true);
            let after = config.to_string();
            if after != before {
                tx.execute("UPDATE agent_configuration SET config=?2,version=?3,updated_by='seed',updated=?4 WHERE agent=?1",params![id,after,version+1,now()])?;
                tx.execute("INSERT INTO agent_configuration_audit(agent,actor,source,version,before_json,after_json,created) VALUES (?1,'seed','entry-greeting-default',?2,?3,?4,?5)",params![id,version+1,before,after,now()])?;
            }
        }
    }
    tx.execute(
        "INSERT INTO metadata VALUES ('agent-entry-greeting-v1','applied')",
        [],
    )?;
    Ok(())
}
#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub display_name: String,
    pub gender: String,
    pub voice: String,
    pub system_prompt: String,
    pub enabled: bool,
    pub tools: Vec<String>,
    pub actions: Vec<String>,
    pub greeting: bool,
    #[serde(default = "default_activation_mode")]
    pub activation_mode: String,
    #[serde(default = "default_muted_timeout")]
    pub muted_idle_seconds: i64,
    pub language: String,
    pub idle_seconds: i64,
    pub session_seconds: i64,
}
fn default_activation_mode() -> String {
    "automatic".into()
}
fn default_muted_timeout() -> i64 {
    5
}
pub fn defaults(id: &str) -> Config {
    let (name,role)=match id {
        "mona"=>("Mona","You are the system office coordinator. Help authorized administrators configure the other agents when requested. Delegate all workspace lookups and configuration changes to the provided tools."),
        "dev-agent"=>("Atlas","You are a software engineer. Help implement and debug software."),
        "qa-agent"=>("Iris","You are a quality engineer. Review risks and develop test plans."),
        "pm-agent"=>("Nova","You are a product manager. Clarify requirements and prioritize work."),
        "sales-agent"=>("Leo","You are a sales assistant. Help qualify leads and draft pitches."),
        _=>("Luna","You are a customer support assistant. Help troubleshoot customer issues."),
    };
    let (gender, voice) = match id {
        "mona" => ("female", "marin"),
        "qa-agent" => ("female", "sage"),
        "pm-agent" => ("female", "coral"),
        "cskh-agent" => ("female", "shimmer"),
        "sales-agent" => ("male", "ash"),
        _ => ("male", "cedar"),
    };
    Config {
        display_name: name.into(),
        gender: gender.into(),
        voice: voice.into(),
        system_prompt: role.into(),
        enabled: true,
        tools: if id == "mona" {
            vec!["workspace", "tasks", "agent_management", "room_control"]
        } else {
            vec!["workspace", "tasks"]
        }
        .into_iter()
        .map(String::from)
        .collect(),
        actions: if id == "mona" {
            vec![
                "workspace.read",
                "tasks.propose",
                "agents.read",
                "agents.configure",
                "agents.reset",
                "rooms.select",
                "rooms.pause",
                "rooms.resume",
            ]
        } else {
            vec!["workspace.read", "tasks.propose"]
        }
        .into_iter()
        .map(String::from)
        .collect(),
        greeting: true,
        activation_mode: default_activation_mode(),
        muted_idle_seconds: default_muted_timeout(),
        language: "en".into(),
        idle_seconds: 60,
        session_seconds: 600,
    }
}
pub fn load(db: &Connection, id: &str) -> Result<(Config, i64), ApiError> {
    if !IDS.contains(&id) {
        return Err(err(StatusCode::NOT_FOUND, "unknown resident agent"));
    }
    let row: Option<(String, i64)> = db
        .query_row(
            "SELECT config,version FROM agent_configuration WHERE agent=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(db_error)?;
    match row {
        Some((raw, v)) => Ok((
            serde_json::from_str(&raw).map_err(|_| {
                err(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "invalid saved agent configuration",
                )
            })?,
            v,
        )),
        None => Ok((defaults(id), 0)),
    }
}
pub fn can_manage(db: &Connection, who: &str) -> Result<bool, ApiError> {
    db.query_row("SELECT EXISTS(SELECT 1 FROM actor_roles WHERE actor=?1 AND role IN ('org-admin','agent-admin'))",[who],|r|r.get(0)).map_err(db_error)
}
pub fn voices() -> Value {
    // Presentation labels are not a speaker identity or an inference about a human.
    let groups = [
        (
            "feminine",
            vec![
                "marin", "coral", "sage", "shimmer", "quartz", "willow", "gleam", "bossa", "delta",
                "nuri", "juni", "brise", "nira", "harema", "noeul",
            ],
        ),
        (
            "masculine",
            vec![
                "cedar", "ash", "ballad", "echo", "verse", "ripple", "vesper", "stone", "meridian",
                "tempo", "beacon", "cinder", "flitz", "sillage", "shida",
            ],
        ),
        ("neutral", vec!["alloy"]),
    ];
    json!(groups
        .into_iter()
        .flat_map(|(presentation, ids)| ids
            .into_iter()
            .map(move |id| json!({"id":id,"presentation":presentation,"label":id})))
        .collect::<Vec<_>>())
}
pub fn recommended_voice(gender: &str) -> &'static str {
    if gender == "male" {
        "cedar"
    } else {
        "marin"
    }
}
pub fn voice_matches_gender(gender: &str, voice: &str) -> bool {
    let presentation = match gender {
        "female" => "feminine",
        "male" => "masculine",
        _ => return true,
    };
    voices()
        .as_array()
        .unwrap()
        .iter()
        .any(|v| v["id"] == voice && v["presentation"] == presentation)
}
pub fn catalog() -> Value {
    let actions = [
        (
            "workspace.read",
            "workspace",
            "Read public workspace projects and tasks",
            false,
        ),
        (
            "tasks.propose",
            "tasks",
            "Propose a task; the requesting user must approve creation",
            false,
        ),
        (
            "agents.read",
            "agent_management",
            "Inspect agent configuration",
            true,
        ),
        (
            "agents.configure",
            "agent_management",
            "Update another agent's identity, voice, prompt, capabilities and limits",
            true,
        ),
        (
            "agents.reset",
            "agent_management",
            "Restore another agent's default configuration",
            true,
        ),
        (
            "rooms.select",
            "room_control",
            "Select the resident speaker in a room",
            true,
        ),
        (
            "rooms.pause",
            "room_control",
            "Pause a room voice agent",
            true,
        ),
        (
            "rooms.resume",
            "room_control",
            "Resume a room voice agent",
            true,
        ),
    ];
    let mut list:Vec<Value>=actions.into_iter().map(|(id,tool,label,admin)|json!({"id":id,"tool":tool,"label":label,"supported":true,"admin_required":admin,"mona_only":admin})).collect();
    for (id, label) in [
        ("tasks.update", "Update or assign tasks"),
        ("projects.create", "Create projects"),
        ("documents.read", "Read documents"),
        ("documents.write", "Write documents"),
        ("customers.read", "Read customer records"),
        ("customers.write", "Change customer records"),
        ("sales.manage", "Manage sales opportunities"),
        ("support.manage", "Manage support cases"),
        ("meetings.manage", "Manage meetings"),
        ("whiteboard.write", "Edit whiteboards"),
        ("leave.manage", "Manage leave requests"),
        ("finance.read", "Read financial records"),
        ("finance.approve", "Approve financial transactions"),
        ("people.manage", "Manage people and account permissions"),
        ("agents.create", "Create additional agent identities"),
        ("agents.delete", "Delete agent identities"),
        ("messages.send", "Send external messages"),
        ("code.execute", "Execute code or shell commands"),
        ("web.search", "Search the web"),
        ("integrations.manage", "Connect external integrations"),
    ] {
        list.push(json!({"id":id,"label":label,"supported":false,"reason":"No authorized live-agent adapter is installed"}));
    }
    json!({"tools":["workspace","tasks","agent_management","room_control"],"actions":list,"voices":voices(),"genders":["female","male","nonbinary","unspecified"],"languages":["auto","en","vi"],"activation_modes":["voice","automatic"],"voice_filter_note":"Voice presentation is a catalog label; agent gender is a separate persona setting."})
}
pub fn allowed(db: &Connection, id: &str, action: &str) -> Result<(), ApiError> {
    let (c, _) = load(db, id)?;
    let list = catalog();
    let entry = list["actions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == action && v["supported"] == true)
        .ok_or(err(StatusCode::FORBIDDEN, "unsupported agent action"))?;
    let tool = entry["tool"].as_str().unwrap();
    if !c.enabled
        || !c.actions.iter().any(|s| s == action)
        || !c.tools.iter().any(|s| s == tool)
        || (entry["mona_only"] == true && id != "mona")
    {
        return Err(err(StatusCode::FORBIDDEN, "agent capability is disabled"));
    }
    Ok(())
}
fn validate(id: &str, c: &Config) -> Result<(), ApiError> {
    if c.display_name.trim().is_empty()
        || c.display_name.chars().count() > 60
        || c.system_prompt.len() > 16000
        || !matches!(
            c.gender.as_str(),
            "female" | "male" | "nonbinary" | "unspecified"
        )
        || !matches!(c.language.as_str(), "auto" | "en" | "vi")
        || !matches!(c.activation_mode.as_str(), "voice" | "automatic")
        || !(1..=600).contains(&c.muted_idle_seconds)
        || !(5..=600).contains(&c.idle_seconds)
        || !(30..=3600).contains(&c.session_seconds)
        || c.tools.len() > 4
        || c.actions.len() > 8
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid agent configuration"));
    }
    if !voices()
        .as_array()
        .unwrap()
        .iter()
        .any(|v| v["id"] == c.voice)
    {
        return Err(err(StatusCode::BAD_REQUEST, "unsupported voice"));
    }
    if !voice_matches_gender(&c.gender, &c.voice) {
        return Err(err(
            StatusCode::BAD_REQUEST,
            "voice must match the selected Female or Male preset",
        ));
    }
    let cat = catalog();
    for tool in &c.tools {
        if !cat["tools"].as_array().unwrap().iter().any(|v| v == tool) {
            return Err(err(StatusCode::BAD_REQUEST, "unsupported tool"));
        }
    }
    for action in &c.actions {
        let entry = cat["actions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["id"] == *action && v["supported"] == true)
            .ok_or(err(StatusCode::BAD_REQUEST, "unsupported action"))?;
        if !c.tools.iter().any(|t| entry["tool"] == *t)
            || (entry["mona_only"] == true && id != "mona")
        {
            return Err(err(
                StatusCode::BAD_REQUEST,
                "action requires its tool and authorized agent type",
            ));
        }
    }
    Ok(())
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Update {
    pub version: i64,
    pub config: Config,
}
pub fn save(
    db: &mut Connection,
    who: &str,
    id: &str,
    body: Update,
    source: &str,
) -> Result<Value, ApiError> {
    if !can_manage(db, who)? {
        return Err(err(
            StatusCode::FORBIDDEN,
            "agent administration permission required",
        ));
    }
    validate(id, &body.config)?;
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let (before, version) = load(&tx, id)?;
    if version != body.version {
        return Err(err(
            StatusCode::CONFLICT,
            "agent changed; reload configuration",
        ));
    }
    let after = serde_json::to_string(&body.config).unwrap();
    tx.execute("INSERT INTO agent_configuration VALUES (?1,?2,?3,?4,?5) ON CONFLICT(agent) DO UPDATE SET config=excluded.config,version=excluded.version,updated_by=excluded.updated_by,updated=excluded.updated",params![id,after,version+1,who,now()]).map_err(db_error)?;
    tx.execute("INSERT INTO agent_configuration_audit(agent,actor,source,version,before_json,after_json,created) VALUES (?1,?2,?3,?4,?5,?6,?7)",params![id,who,source,version+1,serde_json::to_string(&before).unwrap(),after,now()]).map_err(db_error)?;
    tx.execute("INSERT INTO security_audit(actor,subject,action,created) VALUES (?1,?2,'agent_configuration_updated',?3)",params![who,id,now()]).map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    Ok(json!({"id":id,"version":version+1,"config":body.config}))
}
pub fn listing(db: &Connection, who: &str) -> Result<Value, ApiError> {
    let manage = can_manage(db, who)?;
    let agents=IDS.iter().map(|id|{let (c,v)=load(db,id)?;Ok(json!({"id":id,"version":v,"config":if manage {serde_json::to_value(c).unwrap()}else{json!({"display_name":c.display_name,"gender":c.gender,"voice":c.voice,"enabled":c.enabled,"activation_mode":c.activation_mode,"idle_seconds":c.idle_seconds,"muted_idle_seconds":c.muted_idle_seconds})}}))}).collect::<Result<Vec<_>,ApiError>>()?;
    Ok(json!({"agents":agents,"can_manage":manage,"catalog":catalog()}))
}
/// Office-wide appearance metadata only; never includes prompts or permissions.
pub async fn appearances(
    State(db): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let db = db.lock().unwrap();
    actor(&db, &headers)?;
    let agents = IDS.iter().map(|id| {
        let (config, _) = load(&db, id)?;
        Ok(json!({"id":id,"name":config.display_name,"gender":config.gender,"voice":config.voice}))
    }).collect::<Result<Vec<_>, ApiError>>()?;
    Ok(Json(json!(agents)))
}
pub async fn list(State(db): State<Db>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let db = db.lock().unwrap();
    let who = actor(&db, &headers)?;
    Ok(Json(listing(&db, &who)?))
}
pub async fn update(
    State(db): State<Db>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(body): Json<Update>,
) -> Result<Json<Value>, ApiError> {
    let mut db = db.lock().unwrap();
    let who = actor(&db, &headers)?;
    Ok(Json(save(&mut db, &who, &id, body, "workspace")?))
}
pub async fn audit(State(db): State<Db>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    let db = db.lock().unwrap();
    let who = actor(&db, &headers)?;
    if !can_manage(&db, &who)? {
        return Err(err(
            StatusCode::FORBIDDEN,
            "agent administration permission required",
        ));
    }
    let mut q=db.prepare("SELECT agent,actor,source,version,created FROM agent_configuration_audit ORDER BY seq DESC LIMIT 100").map_err(db_error)?;
    let rows=q.query_map([],|r|Ok(json!({"agent":r.get::<_,String>(0)?,"actor":r.get::<_,String>(1)?,"source":r.get::<_,String>(2)?,"version":r.get::<_,i64>(3)?,"created":r.get::<_,i64>(4)?}))).map_err(db_error)?.collect::<Result<Vec<_>,_>>().map_err(db_error)?;
    Ok(Json(json!(rows)))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn db() -> Connection {
        let mut db = Connection::open_in_memory().unwrap();
        super::super::initialize(
            &mut db,
            include_str!("../../../data/seed/nviai/seed.v1.json"),
        )
        .unwrap();
        // These unit cases exercise the legacy, unconfigured version-zero state.
        db.execute_batch("DELETE FROM agent_configuration; DELETE FROM agent_configuration_audit;")
            .unwrap();
        db.execute(
            "INSERT OR IGNORE INTO actor_roles VALUES ('an','org-admin')",
            [],
        )
        .unwrap();
        db
    }
    #[test]
    fn presets_seed_once_preserving_custom_settings_and_auditing_changes() {
        let mut db = db();
        db.execute("DELETE FROM metadata WHERE key='seed-agent-presets-v1'", [])
            .unwrap();
        let mut custom = defaults("dev-agent");
        custom.gender = "female".into();
        custom.voice = "marin".into();
        save(
            &mut db,
            "an",
            "dev-agent",
            Update {
                version: 0,
                config: custom,
            },
            "workspace",
        )
        .unwrap();
        let mut legacy = defaults("qa-agent");
        legacy.gender = "unspecified".into();
        legacy.idle_seconds = 180;
        save(
            &mut db,
            "an",
            "qa-agent",
            Update {
                version: 0,
                config: legacy,
            },
            "workspace",
        )
        .unwrap();
        let tx = db.transaction().unwrap();
        seed(&tx).unwrap();
        tx.commit().unwrap();
        assert_eq!(load(&db, "dev-agent").unwrap().0.voice, "marin");
        let (qa, version) = load(&db, "qa-agent").unwrap();
        assert_eq!(qa.gender, "female");
        assert_eq!(qa.voice, "sage");
        assert_eq!(qa.idle_seconds, 180);
        assert_eq!(version, 2);
        for id in IDS {
            let (c, v) = load(&db, id).unwrap();
            assert!(v > 0);
            validate(id, &c).unwrap();
        }
        let audits: i64 = db
            .query_row("SELECT COUNT(*) FROM agent_configuration_audit", [], |r| {
                r.get(0)
            })
            .unwrap();
        let tx = db.transaction().unwrap();
        seed(&tx).unwrap();
        tx.commit().unwrap();
        assert_eq!(load(&db, "qa-agent").unwrap().1, version);
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM agent_configuration_audit", [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap(),
            audits
        );
    }
    #[test]
    fn old_configurations_default_to_voice_and_timeout_settings_round_trip() {
        let mut value = serde_json::to_value(defaults("mona")).unwrap();
        value.as_object_mut().unwrap().remove("activation_mode");
        value.as_object_mut().unwrap().remove("muted_idle_seconds");
        let old: Config = serde_json::from_value(value).unwrap();
        assert_eq!(old.activation_mode, "automatic");
        assert_eq!(old.muted_idle_seconds, 5);
        let mut db = db();
        let mut config = defaults("mona");
        config.activation_mode = "automatic".into();
        config.idle_seconds = 180;
        config.muted_idle_seconds = 30;
        let _ = save(
            &mut db,
            "an",
            "mona",
            Update { version: 0, config },
            "workspace",
        )
        .unwrap();
        let (saved, _) = load(&db, "mona").unwrap();
        assert_eq!(saved.activation_mode, "automatic");
        assert_eq!(saved.idle_seconds, 180);
        assert_eq!(saved.muted_idle_seconds, 30);
    }
    #[test]
    fn invalid_activation_and_timeouts_are_rejected() {
        let mut config = defaults("mona");
        config.activation_mode = "always_bill".into();
        assert!(validate("mona", &config).is_err());
        config.activation_mode = "voice".into();
        config.idle_seconds = 601;
        assert!(validate("mona", &config).is_err());
        config.idle_seconds = 60;
        config.muted_idle_seconds = 0;
        assert!(validate("mona", &config).is_err());
    }
    #[test]
    fn female_and_male_presets_require_matching_voices() {
        let mut db = db();
        let mut c = defaults("mona");
        assert_eq!(c.gender, "female");
        assert_eq!(c.voice, "marin");
        c.gender = "male".into();
        assert!(save(
            &mut db,
            "an",
            "mona",
            Update {
                version: 0,
                config: c.clone()
            },
            "workspace"
        )
        .is_err());
        c.voice = "cedar".into();
        let _ = save(
            &mut db,
            "an",
            "mona",
            Update {
                version: 0,
                config: c,
            },
            "workspace",
        )
        .unwrap();
        let (saved, _) = load(&db, "mona").unwrap();
        assert_eq!(saved.gender, "male");
        assert_eq!(saved.voice, "cedar");
    }
    #[test]
    fn mona_gender_only_setup_selects_a_corresponding_voice() {
        let mut db = db();
        let (before, v) = load(&db, "dev-agent").unwrap();
        assert_eq!(before.gender, "male");
        let result = delegated(
            &mut db,
            "an",
            "agents.configure",
            "dev-agent",
            Some(v),
            json!({"gender":"female"}),
        )
        .unwrap();
        assert_eq!(result["config"]["gender"], "female");
        assert_eq!(result["config"]["voice"], "marin");
    }
    #[test]
    fn configuration_is_persistent_versioned_and_audited() {
        let mut db = db();
        let mut c = defaults("dev-agent");
        c.voice = "cedar".into();
        c.gender = "male".into();
        let saved = save(
            &mut db,
            "an",
            "dev-agent",
            Update {
                version: 0,
                config: c.clone(),
            },
            "workspace",
        )
        .unwrap();
        assert_eq!(saved["version"], 1);
        assert_eq!(load(&db, "dev-agent").unwrap().0.voice, "cedar");
        assert!(save(
            &mut db,
            "an",
            "dev-agent",
            Update {
                version: 0,
                config: c
            },
            "workspace"
        )
        .is_err());
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM agent_configuration_audit", [], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap(),
            1
        );
    }
    #[test]
    fn unauthorized_user_cannot_write_or_read_system_prompts() {
        let mut db = db();
        assert!(save(
            &mut db,
            "van",
            "dev-agent",
            Update {
                version: 0,
                config: defaults("dev-agent")
            },
            "workspace"
        )
        .is_err());
        let view = listing(&db, "van").unwrap();
        assert_eq!(view["can_manage"], false);
        assert!(view["agents"][0]["config"].get("system_prompt").is_none());
    }
    #[test]
    fn unsupported_actions_and_management_on_non_system_agents_are_rejected() {
        let mut db = db();
        let mut c = defaults("dev-agent");
        c.actions.push("code.execute".into());
        assert!(save(
            &mut db,
            "an",
            "dev-agent",
            Update {
                version: 0,
                config: c
            },
            "workspace"
        )
        .is_err());
        let mut c = defaults("dev-agent");
        c.tools.push("agent_management".into());
        c.actions.push("agents.configure".into());
        assert!(save(
            &mut db,
            "an",
            "dev-agent",
            Update {
                version: 0,
                config: c
            },
            "workspace"
        )
        .is_err());
    }
    #[test]
    fn removing_action_or_tool_is_enforced_on_the_server() {
        let mut db = db();
        let mut c = defaults("mona");
        c.tools.retain(|v| v != "tasks");
        c.actions.retain(|v| v != "tasks.propose");
        save(
            &mut db,
            "an",
            "mona",
            Update {
                version: 0,
                config: c,
            },
            "workspace",
        )
        .unwrap();
        assert!(allowed(&db, "mona", "tasks.propose").is_err());
        assert!(allowed(&db, "mona", "workspace.read").is_ok());
    }
}

/// Shared by authenticated text Mona and room-voice Mona; neither can grant itself powers.
pub fn delegated(
    db: &mut Connection,
    who: &str,
    action: &str,
    target: &str,
    expected: Option<i64>,
    changes: Value,
) -> Result<Value, ApiError> {
    if !can_manage(db, who)? {
        return Err(err(
            StatusCode::FORBIDDEN,
            "agent administration permission required",
        ));
    }
    allowed(db, "mona", action)?;
    if action == "agents.read" {
        return listing(db, who);
    }
    if !matches!(action, "agents.configure" | "agents.reset") || target == "mona" {
        return Err(err(
            StatusCode::FORBIDDEN,
            "Mona may configure other existing agents only",
        ));
    }
    let (config, version) = load(db, target)?;
    if expected != Some(version) {
        return Err(err(
            StatusCode::CONFLICT,
            "configuration changed; inspect it again",
        ));
    }
    let mut value = serde_json::to_value(config).unwrap();
    if action == "agents.reset" {
        value = serde_json::to_value(defaults(target)).unwrap()
    } else {
        for (key, item) in changes
            .as_object()
            .ok_or(err(StatusCode::BAD_REQUEST, "changes must be an object"))?
        {
            value[key] = item.clone();
        }
    }
    if let Some(gender) = changes.get("gender").and_then(|v| v.as_str()) {
        if changes.get("voice").is_none()
            && matches!(gender, "male" | "female")
            && !voice_matches_gender(gender, value["voice"].as_str().unwrap_or(""))
        {
            value["voice"] = json!(recommended_voice(gender));
        }
    }
    let config = serde_json::from_value(value)
        .map_err(|_| err(StatusCode::BAD_REQUEST, "invalid configuration changes"))?;
    save(db, who, target, Update { version, config }, "mona")
}

#[derive(Deserialize)]
pub struct Reset {
    version: i64,
}
pub async fn reset(
    State(db): State<Db>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(body): Json<Reset>,
) -> Result<Json<Value>, ApiError> {
    let mut db = db.lock().unwrap();
    let who = actor(&db, &headers)?;
    Ok(Json(save(
        &mut db,
        &who,
        &id,
        Update {
            version: body.version,
            config: defaults(&id),
        },
        "workspace_reset",
    )?))
}
