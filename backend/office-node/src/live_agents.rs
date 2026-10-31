//! Authoritative room voice agents: fenced workers, scoped commands and approvals.
use super::{actor, db_error, err, hash, now, permitted, realtime_epoch, ApiError, Db};
use crate::media::MediaControl;
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Extension, Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::{HashMap, VecDeque},
    sync::{Arc, Mutex},
    time::Duration,
};

pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS live_agent_settings(room TEXT PRIMARY KEY REFERENCES rooms(id), agent TEXT NOT NULL REFERENCES actors(id), paused INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS live_agent_sessions(id TEXT PRIMARY KEY,room TEXT NOT NULL,agent TEXT NOT NULL,epoch INTEGER NOT NULL,started INTEGER NOT NULL,ended INTEGER,seconds REAL NOT NULL DEFAULT 0,state TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS live_agent_operations(id TEXT PRIMARY KEY,actor TEXT NOT NULL REFERENCES actors(id),room TEXT NOT NULL,agent TEXT NOT NULL,project TEXT NOT NULL REFERENCES projects(id),title TEXT NOT NULL,state TEXT NOT NULL DEFAULT 'pending',created INTEGER NOT NULL,result TEXT);
CREATE TABLE IF NOT EXISTS live_agent_daily_usage(day INTEGER PRIMARY KEY,seconds REAL NOT NULL DEFAULT 0);
INSERT OR IGNORE INTO live_agent_daily_usage SELECT started/86400,SUM(seconds) FROM live_agent_sessions GROUP BY started/86400;")
}
pub fn residents(room: &str) -> &'static [&'static str] {
    match room {
        "lobby" => &["mona"],
        "dev" => &["dev-agent", "qa-agent"],
        "product" => &["pm-agent"],
        "sales" => &["sales-agent"],
        "support" => &["cskh-agent"],
        _ => &[],
    }
}
fn limit(name: &str, default: i64, min: i64, max: i64) -> i64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
        .clamp(min, max)
}
#[derive(Clone)]
struct Person {
    actor: String,
    room: String,
    epoch: u64,
    updated: i64,
}
#[derive(Clone)]
struct Lease {
    id: String,
    agent: String,
    epoch: u64,
    updated: i64,
    started: i64,
    revision: i64,
    state: String,
    message: String,
}
#[derive(Default)]
struct Memory {
    people: HashMap<String, Person>,
    leases: HashMap<String, Lease>,
    captions: HashMap<String, VecDeque<Value>>,
    errors: HashMap<String, String>,
}
pub struct Service {
    db: Db,
    enabled: bool,
    credential: String,
    memory: Mutex<Memory>,
    media: Mutex<Option<Arc<MediaControl>>>,
}
impl Service {
    pub fn new(db: Db) -> Result<Arc<Self>, Box<dyn std::error::Error>> {
        let enabled = std::env::var("LIVE_AGENTS_ENABLED").as_deref() == Ok("1")
            && super::auth::role(&db.lock().unwrap())? == Some(super::auth::Role::Master);
        let credential = if enabled {
            let path = super::runtime_paths::directory()?.join("live-agent/worker.token");
            super::runtime_paths::create_parent(&path)?;
            if !path.exists() {
                use std::io::Write;
                let mut options = std::fs::OpenOptions::new();
                options.write(true).create_new(true);
                #[cfg(unix)]
                {
                    use std::os::unix::fs::OpenOptionsExt;
                    options.mode(0o600);
                }
                options.open(&path)?.write_all(
                    format!(
                        "{}{}",
                        uuid::Uuid::new_v4().simple(),
                        uuid::Uuid::new_v4().simple()
                    )
                    .as_bytes(),
                )?;
            }
            std::fs::read_to_string(path)?.trim().to_string()
        } else {
            String::new()
        };
        if enabled {
            db.lock().unwrap().execute(
                "UPDATE live_agent_sessions SET ended=?1,state='closed' WHERE ended IS NULL",
                params![now()],
            )?;
        }
        let service = Arc::new(Self {
            db,
            enabled,
            credential,
            memory: Mutex::default(),
            media: Mutex::default(),
        });
        let weak = Arc::downgrade(&service);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(1)).await;
                let Some(s) = weak.upgrade() else { break };
                s.sweep();
            }
        });
        Ok(service)
    }
    pub fn attach_media(&self, media: Arc<MediaControl>) {
        *self.media.lock().unwrap() = Some(media);
    }
    pub fn observe(&self, actor: &str, session: &str, room: &str, epoch: u64) {
        if self.enabled {
            self.memory.lock().unwrap().people.insert(
                session.into(),
                Person {
                    actor: actor.into(),
                    room: room.into(),
                    epoch,
                    updated: now(),
                },
            );
        }
    }
    pub fn leave(&self, session: &str) {
        self.memory.lock().unwrap().people.remove(session);
        self.sweep();
    }
    fn worker(&self, headers: &HeaderMap) -> Result<(), ApiError> {
        let value = headers
            .get("authorization")
            .and_then(|h| h.to_str().ok())
            .and_then(|s| s.strip_prefix("Bearer "))
            .unwrap_or("");
        if !self.enabled || self.credential.is_empty() || hash(value) != hash(&self.credential) {
            return Err(err(
                StatusCode::UNAUTHORIZED,
                "worker authentication required",
            ));
        }
        Ok(())
    }
    fn users(db: &Connection, mem: &Memory, room: &str, epoch: u64) -> Vec<Value> {
        mem.people
            .iter()
            .filter(|(_, p)| {
                p.room == room
                    && now() - p.updated <= 20
                    && p.epoch >= epoch
                    && permitted(db, &p.actor, room).unwrap_or(false)
            })
            .map(|(s, p)| json!({"actor":p.actor,"session":s}))
            .collect()
    }
    fn settings(db: &Connection, room: &str) -> Result<(String, bool), ApiError> {
        db.query_row(
            "SELECT agent,paused FROM live_agent_settings WHERE room=?1",
            [room],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(db_error)
        .map(|v| v.unwrap_or_else(|| (residents(room).first().unwrap_or(&"").to_string(), false)))
    }
    fn validate(
        &self,
        db: &Connection,
        mem: &Memory,
        room: &str,
        id: &str,
    ) -> Result<Lease, ApiError> {
        let epoch = realtime_epoch(db).map_err(db_error)?;
        let lease = mem
            .leases
            .get(room)
            .filter(|l| l.id == id && l.epoch == epoch && now() - l.updated <= 12)
            .cloned()
            .ok_or(err(StatusCode::CONFLICT, "agent lease expired"))?;
        let (agent, paused) = Self::settings(db, room)?;
        let (config, revision) = super::agent_config::load(db, &lease.agent)?;
        if paused
            || !config.enabled
            || revision != lease.revision
            || agent != lease.agent
            || Self::users(db, mem, room, epoch).is_empty()
        {
            return Err(err(StatusCode::CONFLICT, "room agent inactive"));
        }
        Ok(lease)
    }
    fn requesting_actor(
        &self,
        db: &Connection,
        mem: &Memory,
        room: &str,
        id: &str,
        who: &str,
    ) -> Result<Lease, ApiError> {
        let lease = self.validate(db, mem, room, id)?;
        if !Self::users(db, mem, room, lease.epoch)
            .iter()
            .any(|u| u["actor"] == who)
        {
            return Err(err(
                StatusCode::FORBIDDEN,
                "speaker is no longer authorized in this room",
            ));
        }
        Ok(lease)
    }
    fn sweep(&self) {
        if !self.enabled {
            return;
        }
        let db = self.db.lock().unwrap();
        let mut mem = self.memory.lock().unwrap();
        mem.people.retain(|_, p| now() - p.updated <= 20);
        let expired: Vec<_> = mem
            .leases
            .iter()
            .filter(|(room, l)| self.validate(&db, &mem, room, &l.id).is_err())
            .map(|(r, l)| (r.clone(), l.id.clone()))
            .collect();
        for (room, id) in expired {
            mem.leases.remove(&room);
            mem.captions.remove(&room);
            let _ = db.execute(
                "UPDATE live_agent_sessions SET ended=?2,state='closed' WHERE id=?1",
                params![id, now()],
            );
            if let Some(media) = self.media.lock().unwrap().as_ref() {
                media.remove(&id);
            }
        }
    }
}
#[derive(Deserialize)]
pub struct Control {
    action: String,
    agent: Option<String>,
}
pub async fn status(
    State(db): State<Db>,
    Extension(s): Extension<Arc<Service>>,
    headers: HeaderMap,
    Path(room): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let db = db.lock().unwrap();
    let who = actor(&db, &headers)?;
    if !permitted(&db, &who, &room)? {
        return Err(err(StatusCode::FORBIDDEN, "room access denied"));
    }
    let mem = s.memory.lock().unwrap();
    let in_room = Service::users(&db, &mem, &room, realtime_epoch(&db).map_err(db_error)?)
        .iter()
        .any(|u| u["actor"] == who);
    let (selected, paused) = Service::settings(&db, &room)?;
    let epoch = realtime_epoch(&db).map_err(db_error)?;
    let lease = mem
        .leases
        .get(&room)
        .filter(|l| s.validate(&db, &mem, &room, &l.id).is_ok());
    let agent_enabled = super::agent_config::load(&db, &selected)
        .map(|c| c.0.enabled)
        .unwrap_or(true);
    let state = if !s.enabled || !agent_enabled {
        "disabled"
    } else if paused {
        "paused"
    } else if lease.is_some() {
        lease.unwrap().state.as_str()
    } else if mem.errors.contains_key(&room) {
        "error"
    } else {
        "offline"
    };
    let admin: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM actor_roles WHERE actor=?1 AND role='org-admin')",
            [&who],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    let mut q=db.prepare("SELECT id,title,project FROM live_agent_operations WHERE actor=?1 AND room=?2 AND state='pending' ORDER BY created LIMIT 20").map_err(db_error)?;
    let operations=q.query_map(params![who,room],|r|Ok(json!({"id":r.get::<_,String>(0)?,"title":r.get::<_,String>(1)?,"project":r.get::<_,String>(2)?}))).map_err(db_error)?.collect::<Result<Vec<_>,_>>().map_err(db_error)?;
    let appearances: Vec<Value> = residents(&room)
        .iter()
        .filter_map(|id| {
            super::agent_config::load(&db, id).ok().map(|(config, _)| json!({
            "id": id, "name": config.display_name, "gender": config.gender, "voice": config.voice
        }))
        })
        .collect();
    Ok(Json(
        json!({"enabled":s.enabled,"room":room,"appearances":appearances,"agents":residents(&room),"selected":selected,"gender":super::agent_config::load(&db,&selected).ok().map(|c|c.0.gender),"voice":super::agent_config::load(&db,&selected).ok().map(|c|c.0.voice),"activation_mode":super::agent_config::load(&db,&selected).ok().map(|c|c.0.activation_mode),"idle_seconds":super::agent_config::load(&db,&selected).ok().map(|c|c.0.idle_seconds),"muted_idle_seconds":super::agent_config::load(&db,&selected).ok().map(|c|c.0.muted_idle_seconds),"display_name":super::agent_config::load(&db,&selected).ok().map(|c|c.0.display_name),"state":state,"message":lease.map(|l|l.message.clone()).or_else(||mem.errors.get(&room).cloned()),"can_control":admin,"users":Service::users(&db,&mem,&room,epoch),"captions":if in_room { mem.captions.get(&room) } else { None },"operations":operations}),
    ))
}
pub async fn control(
    State(db): State<Db>,
    Extension(s): Extension<Arc<Service>>,
    headers: HeaderMap,
    Path(room): Path<String>,
    Json(body): Json<Control>,
) -> Result<Json<Value>, ApiError> {
    let db = db.lock().unwrap();
    let who = actor(&db, &headers)?;
    if !permitted(&db, &who, &room)? || residents(&room).is_empty() {
        return Err(err(StatusCode::FORBIDDEN, "room access denied"));
    }
    let (mut agent, mut paused) = Service::settings(&db, &room)?;
    let admin: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM actor_roles WHERE actor=?1 AND role='org-admin')",
            [&who],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    match body.action.as_str() {
        "pause" | "resume" if admin => paused = body.action == "pause",
        "select" => {
            let epoch = realtime_epoch(&db).map_err(db_error)?;
            if !Service::users(&db, &s.memory.lock().unwrap(), &room, epoch)
                .iter()
                .any(|u| u["actor"] == who)
            {
                return Err(err(
                    StatusCode::FORBIDDEN,
                    "enter the room to select its agent",
                ));
            }
            let chosen = body.agent.unwrap_or_default();
            if !residents(&room).contains(&chosen.as_str()) {
                return Err(err(
                    StatusCode::BAD_REQUEST,
                    "agent is not assigned to this room",
                ));
            }
            agent = chosen;
        }
        _ => return Err(err(StatusCode::FORBIDDEN, "control is not permitted")),
    }
    db.execute("INSERT INTO live_agent_settings VALUES (?1,?2,?3) ON CONFLICT(room) DO UPDATE SET agent=excluded.agent,paused=excluded.paused",params![room,agent,paused]).map_err(db_error)?;
    db.execute("INSERT INTO security_audit(actor,subject,action,created) VALUES (?1,?2,'live_agent_control',?3)",params![who,room,now()]).map_err(db_error)?;
    drop(db);
    s.sweep();
    Ok(Json(json!({"ok":true})))
}
pub async fn plans(
    Extension(s): Extension<Arc<Service>>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    s.worker(&headers)?;
    s.sweep();
    let db = s.db.lock().unwrap();
    let mem = s.memory.lock().unwrap();
    let epoch = realtime_epoch(&db).map_err(db_error)?;
    let rooms: Vec<_> = ["lobby", "dev", "product", "sales", "support"]
        .iter()
        .filter_map(|room| {
            let (agent, paused) = Service::settings(&db, room).ok()?;
            let users = Service::users(&db, &mem, room, epoch);
            let (config,revision)=super::agent_config::load(&db,&agent).ok()?;
            if paused || !config.enabled || users.is_empty() {
                None
            } else {
                {
                    let mut attention = Vec::new();
                    if super::workflow::channel(&db).ok().as_deref() == Some("voice") {
                        for user in &users {
                            if let Some(actor) = user["actor"].as_str() {
                                let pending: i64 = db.query_row("SELECT COUNT(*) FROM task_notifications WHERE recipient=?1 AND read=0",[actor],|r|r.get(0)).unwrap_or(0);
                                if pending > 0 {
                                    let public_question: Option<String> = db.query_row("SELECT q.question FROM job_questions q JOIN agent_jobs j ON j.id=q.job JOIN tasks t ON t.id=j.task WHERE j.created_by=?1 AND q.answer IS NULL AND j.state='waiting_input' AND NOT EXISTS(SELECT 1 FROM project_rules WHERE project=t.project) ORDER BY q.created DESC LIMIT 1",[actor],|r|r.get(0)).optional().ok().flatten();
                                    attention.push(json!({"actor":actor,"count":pending,"public_question":public_question}));
                                }
                            }
                        }
                    }
                    attention.sort_by_key(|a| a["actor"].as_str().unwrap_or("").to_owned());
                    attention.dedup_by(|a,b| a["actor"] == b["actor"]);
                    Some(json!({"room":room,"agent":agent,"users":users,"epoch":epoch,"revision":revision,"config":config,"attention":attention}))
                }
            }
        })
        .collect();
    Ok(Json(
        json!({"rooms":rooms,"max_concurrent":limit("LIVE_AGENT_MAX_CONCURRENT_SESSIONS",4,1,12),"idle_seconds":limit("LIVE_AGENT_IDLE_TIMEOUT_SECONDS",60,5,600),"max_idle_seconds":limit("LIVE_AGENT_MAX_IDLE_TIMEOUT_SECONDS",600,5,600),"session_seconds":limit("LIVE_AGENT_MAX_SESSION_SECONDS",600,30,3600)}),
    ))
}
#[derive(Deserialize)]
pub struct Claim {
    agent: String,
}
pub async fn claim(
    Extension(s): Extension<Arc<Service>>,
    headers: HeaderMap,
    Path(room): Path<String>,
    Json(body): Json<Claim>,
) -> Result<Json<Value>, ApiError> {
    s.worker(&headers)?;
    s.sweep();
    let media = s
        .media
        .lock()
        .unwrap()
        .clone()
        .ok_or(err(StatusCode::SERVICE_UNAVAILABLE, "media unavailable"))?;
    let lease = {
        let db = s.db.lock().unwrap();
        let mut mem = s.memory.lock().unwrap();
        let epoch = realtime_epoch(&db).map_err(db_error)?;
        let (agent, paused) = Service::settings(&db, &room)?;
        if paused
            || body.agent != agent
            || residents(&room).is_empty()
            || Service::users(&db, &mem, &room, epoch).is_empty()
        {
            return Err(err(StatusCode::CONFLICT, "room agent inactive"));
        }
        if mem.leases.contains_key(&room) {
            return Err(err(
                StatusCode::CONFLICT,
                "room already has an agent worker",
            ));
        }
        if mem.leases.len() >= limit("LIVE_AGENT_MAX_CONCURRENT_SESSIONS", 4, 1, 12) as usize {
            return Err(err(
                StatusCode::TOO_MANY_REQUESTS,
                "live agent concurrency limit",
            ));
        }
        let usage: f64 = db
            .query_row(
                "SELECT COALESCE(SUM(seconds),0) FROM live_agent_daily_usage WHERE day=?1",
                [now() / 86400],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        if usage >= limit("LIVE_AGENT_DAILY_BUDGET_SECONDS", 3600, 30, 86400) as f64 {
            mem.errors.insert(
                room.clone(),
                "Daily voice usage limit reached. Review the server usage budget.".into(),
            );
            return Err(err(
                StatusCode::TOO_MANY_REQUESTS,
                "daily live agent budget reached",
            ));
        }
        let lease = Lease {
            id: uuid::Uuid::new_v4().to_string(),
            agent,
            epoch,
            updated: now(),
            started: now(),
            revision: super::agent_config::load(&db, &body.agent)?.1,
            state: "starting".into(),
            message: String::new(),
        };
        db.execute("INSERT INTO live_agent_sessions(id,room,agent,epoch,started,state) VALUES (?1,?2,?3,?4,?5,'starting')",params![lease.id,room,lease.agent,epoch,lease.started]).map_err(db_error)?;
        mem.errors.remove(&room);
        mem.leases.insert(room.clone(), lease.clone());
        lease
    };
    let grant = media
        .issue_agent(&room, &lease.agent, &lease.id, lease.epoch)
        .await?;
    {
        let db = s.db.lock().unwrap();
        let mem = s.memory.lock().unwrap();
        if let Err(error) = s.validate(&db, &mem, &room, &lease.id) {
            media.remove(&lease.id);
            return Err(error);
        }
    }
    Ok(Json(
        json!({"lease":lease.id,"url":media.client_url(),"token":grant.token,"media_room":grant.room,"identity":grant.identity,"agent":lease.agent,"epoch":lease.epoch}),
    ))
}
#[derive(Deserialize)]
pub struct Report {
    room: String,
    lease: String,
    state: String,
    #[serde(default)]
    message: String,
    #[serde(default)]
    seconds: f64,
    caption: Option<String>,
    speaker: Option<String>,
}
pub async fn report(
    Extension(s): Extension<Arc<Service>>,
    headers: HeaderMap,
    Json(body): Json<Report>,
) -> Result<Json<Value>, ApiError> {
    s.worker(&headers)?;
    if !body.seconds.is_finite()
        || body.seconds < 0.
        || body.message.len() > 300
        || body.caption.as_ref().is_some_and(|c| c.len() > 4000)
        || ![
            "starting",
            "ready",
            "listening",
            "speaking",
            "working",
            "reconnecting",
            "error",
            "closed",
        ]
        .contains(&body.state.as_str())
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid worker report"));
    }
    let db = s.db.lock().unwrap();
    let mut mem = s.memory.lock().unwrap();
    let mut lease = s.validate(&db, &mem, &body.room, &body.lease)?;
    let max = limit("LIVE_AGENT_MAX_SESSION_SECONDS", 600, 30, 3600).min(
        super::agent_config::load(&db, &lease.agent)?
            .0
            .session_seconds,
    );
    let previous: f64 = db
        .query_row(
            "SELECT seconds FROM live_agent_sessions WHERE id=?1",
            [&lease.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    let accounted = body.seconds.max(previous);
    let mut exceeded = accounted >= max as f64;
    lease.updated = now();
    lease.state = body.state.clone();
    lease.message = body.message;
    if body.state == "error" {
        mem.errors.insert(body.room.clone(), lease.message.clone());
    }
    db.execute(
        "UPDATE live_agent_sessions SET seconds=MAX(seconds,?2),state=?3 WHERE id=?1",
        params![lease.id, accounted, lease.state],
    )
    .map_err(db_error)?;
    db.execute("INSERT INTO live_agent_daily_usage VALUES (?1,?2) ON CONFLICT(day) DO UPDATE SET seconds=seconds+excluded.seconds",params![now()/86400,(accounted-previous).max(0.)]).map_err(db_error)?;
    let daily: f64 = db
        .query_row(
            "SELECT COALESCE(SUM(seconds),0) FROM live_agent_daily_usage WHERE day=?1",
            [now() / 86400],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    exceeded |= daily >= limit("LIVE_AGENT_DAILY_BUDGET_SECONDS", 3600, 30, 86400) as f64;
    if exceeded {
        mem.errors.insert(
            body.room.clone(),
            "Voice usage limit reached. An administrator can review limits and resume the agent."
                .into(),
        );
        db.execute("INSERT INTO live_agent_settings VALUES (?1,?2,1) ON CONFLICT(room) DO UPDATE SET paused=1",params![body.room,lease.agent]).map_err(db_error)?;
    }
    if let Some(text) = body.caption.filter(|s| !s.trim().is_empty()) {
        let speaker = body.speaker.unwrap_or_else(|| lease.agent.clone());
        if speaker == lease.agent
            || Service::users(&db, &mem, &body.room, lease.epoch)
                .iter()
                .any(|u| u["actor"] == speaker)
        {
            let queue = mem.captions.entry(body.room.clone()).or_default();
            let merge = queue.back().is_some_and(|v| {
                v["speaker"] == speaker
                    && now() - v["at"].as_i64().unwrap_or(0) <= 2
                    && v["text"].as_str().unwrap_or("").len() + text.len() < 2000
            });
            if merge {
                let last = queue.back_mut().unwrap();
                last["text"] = json!(format!("{}{}", last["text"].as_str().unwrap_or(""), text));
                last["at"] = json!(now());
            } else {
                queue.push_back(json!({"speaker":speaker,"text":text,"at":now()}));
            }
            while queue.len() > 12 {
                queue.pop_front();
            }
        }
    }
    if body.state == "closed" || exceeded {
        mem.leases.remove(&body.room);
        mem.captions.remove(&body.room);
        db.execute(
            "UPDATE live_agent_sessions SET ended=?2 WHERE id=?1",
            params![lease.id, now()],
        )
        .map_err(db_error)?;
        if let Some(media) = s.media.lock().unwrap().as_ref() {
            media.remove(&lease.id);
        }
    } else {
        mem.leases.insert(body.room.clone(), lease.clone());
    }
    let mut q=db.prepare("SELECT id,state FROM live_agent_operations WHERE room=?1 AND agent=?2 AND created>=?3 AND state!='pending' ORDER BY created DESC LIMIT 20").map_err(db_error)?;
    let operations = q
        .query_map(params![body.room, lease.agent, lease.started], |r| {
            Ok(json!({"id":r.get::<_,String>(0)?,"state":r.get::<_,String>(1)?}))
        })
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    Ok(Json(
        json!({"operations":operations,"active":!exceeded && body.state!="closed","users":Service::users(&db,&mem,&body.room,lease.epoch)}),
    ))
}
#[derive(Deserialize)]
pub struct Work {
    room: String,
    lease: String,
    actor: String,
    id: String,
    project: Option<String>,
    title: Option<String>,
}
pub async fn context(
    Extension(s): Extension<Arc<Service>>,
    headers: HeaderMap,
    Json(body): Json<Work>,
) -> Result<Json<Value>, ApiError> {
    s.worker(&headers)?;
    let db = s.db.lock().unwrap();
    let mem = s.memory.lock().unwrap();
    let lease = s.requesting_actor(&db, &mem, &body.room, &body.lease, &body.actor)?;
    super::agent_config::allowed(&db, &lease.agent, "workspace.read")?;
    let mut q=db.prepare("SELECT p.id,p.name FROM projects p WHERE NOT EXISTS(SELECT 1 FROM project_rules r WHERE r.project=p.id) LIMIT 50").map_err(db_error)?;
    let projects = q
        .query_map([], |r| {
            Ok(json!({"id":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?}))
        })
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    let mut q=db.prepare("SELECT t.id,t.title,t.state,t.project FROM tasks t WHERE NOT EXISTS(SELECT 1 FROM project_rules r WHERE r.project=t.project) ORDER BY t.rowid DESC LIMIT 50").map_err(db_error)?;
    let tasks=q.query_map([],|r|Ok(json!({"id":r.get::<_,String>(0)?,"title":r.get::<_,String>(1)?,"state":r.get::<_,String>(2)?,"project":r.get::<_,String>(3)?}))).map_err(db_error)?.collect::<Result<Vec<_>,_>>().map_err(db_error)?;
    let mut q = db.prepare("SELECT q.id,q.question FROM job_questions q JOIN agent_jobs j ON j.id=q.job JOIN tasks t ON t.id=j.task WHERE j.created_by=?1 AND q.answer IS NULL AND j.state='waiting_input' AND NOT EXISTS(SELECT 1 FROM project_rules r WHERE r.project=t.project) LIMIT 10").map_err(db_error)?;
    let questions = q
        .query_map([&body.actor], |r| {
            Ok(json!({"id":r.get::<_,String>(0)?,"question":r.get::<_,String>(1)?}))
        })
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    Ok(Json(
        json!({"projects":projects,"tasks":tasks,"questions":questions,"scope":"workspace-visible records only; private results must not be spoken to the room"}),
    ))
}
pub async fn propose(
    Extension(s): Extension<Arc<Service>>,
    headers: HeaderMap,
    Json(body): Json<Work>,
) -> Result<Json<Value>, ApiError> {
    s.worker(&headers)?;
    let mut db = s.db.lock().unwrap();
    let mem = s.memory.lock().unwrap();
    let lease = s.requesting_actor(&db, &mem, &body.room, &body.lease, &body.actor)?;
    super::agent_config::allowed(&db, &lease.agent, "tasks.propose")?;
    let title = body.title.unwrap_or_default();
    let project = body.project.unwrap_or_default();
    if uuid::Uuid::parse_str(&body.id).is_err() || title.trim().is_empty() || title.len() > 240 {
        return Err(err(StatusCode::BAD_REQUEST, "invalid task proposal"));
    }
    if !super::tasks::can_edit_project(&db, &body.actor, &project)? {
        return Err(err(StatusCode::FORBIDDEN, "project edit access required"));
    }
    let existing: Option<String> = db.query_row("SELECT id FROM live_agent_operations WHERE actor=?1 AND room=?2 AND project=?3 AND title=?4 AND state='pending' ORDER BY created DESC LIMIT 1",params![body.actor,body.room,project,title],|r|r.get(0)).optional().map_err(db_error)?;
    if let Some(existing) = existing {
        if existing != body.id {
            return Ok(Json(
                json!({"id":existing,"state":"pending","message":"The same task proposal is already awaiting approval in your app."}),
            ));
        }
    }
    let tx = db.transaction().map_err(db_error)?;
    let old: Option<(String, String, String)> = tx
        .query_row(
            "SELECT actor,project,title FROM live_agent_operations WHERE id=?1",
            [&body.id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(db_error)?;
    if let Some(old) = old {
        if old != (body.actor.clone(), project.clone(), title.clone()) {
            return Err(err(StatusCode::CONFLICT, "operation ID conflict"));
        }
    } else {
        tx.execute("INSERT INTO live_agent_operations(id,actor,room,agent,project,title,created) VALUES (?1,?2,?3,?4,?5,?6,?7)",params![body.id,body.actor,body.room,lease.agent,project,title,now()]).map_err(db_error)?;
    }
    tx.commit().map_err(db_error)?;
    Ok(Json(
        json!({"id":body.id,"state":"pending","message":"Task proposal saved. The requesting user must approve it in their app before it is created."}),
    ))
}
#[derive(Deserialize)]
pub struct Decision {
    action: String,
}
pub async fn decide(
    State(db): State<Db>,
    Extension(s): Extension<Arc<Service>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(body): Json<Decision>,
) -> Result<Json<Value>, ApiError> {
    if body.action != "approve" && body.action != "reject" {
        return Err(err(StatusCode::BAD_REQUEST, "invalid decision"));
    }
    let mut db = db.lock().unwrap();
    let who = actor(&db, &headers)?;
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let row: Option<(String, String, String, String, String)> = tx
        .query_row(
            "SELECT actor,room,project,title,state FROM live_agent_operations WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (owner, room, project, title, state) =
        row.ok_or(err(StatusCode::NOT_FOUND, "proposal not found"))?;
    if who != owner
        || !permitted(&tx, &who, &room)?
        || !super::tasks::can_edit_project(&tx, &who, &project)?
    {
        return Err(err(
            StatusCode::FORBIDDEN,
            "proposal owner and current permissions required",
        ));
    }
    if state != "pending" {
        return Ok(Json(json!({"id":id,"state":state})));
    }
    let epoch = realtime_epoch(&tx).map_err(db_error)?;
    let mem = s.memory.lock().unwrap();
    if !Service::users(&tx, &mem, &room, epoch)
        .iter()
        .any(|u| u["actor"] == who)
    {
        return Err(err(
            StatusCode::FORBIDDEN,
            "return to the proposal room to confirm",
        ));
    }
    let state = if body.action == "approve" {
        "completed"
    } else {
        "rejected"
    };
    if state == "completed" {
        tx.execute(
            "INSERT INTO tasks VALUES (?1,?2,?3,NULL,'todo',1,?4)",
            params![id, project, title, who],
        )
        .map_err(db_error)?;
        let payload = json!({"id":id,"title":title,"assignee":null,"op":id}).to_string();
        tx.execute("INSERT INTO task_audit(op,request_hash,actor,object_type,object_id,action,created) VALUES (?1,?2,?3,'task',?1,'created',?4)",params![id,hash(&payload),who,now()]).map_err(db_error)?;
    }
    tx.execute(
        "UPDATE live_agent_operations SET state=?2,result=?3 WHERE id=?1",
        params![
            id,
            state,
            if state == "completed" {
                Some(id.clone())
            } else {
                None
            }
        ],
    )
    .map_err(db_error)?;
    tx.execute(
        "INSERT INTO security_audit(actor,subject,action,created) VALUES (?1,?2,?3,?4)",
        params![who, id, format!("live_agent_{}", body.action), now()],
    )
    .map_err(db_error)?;
    tx.commit().map_err(db_error)?;
    Ok(Json(json!({"id":id,"state":state})))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> Arc<Service> {
        let mut db = Connection::open_in_memory().unwrap();
        db.execute_batch("PRAGMA foreign_keys=ON").unwrap();
        super::super::initialize(
            &mut db,
            include_str!("../../../data/seed/nviai/seed.v1.json"),
        )
        .unwrap();
        for who in ["an", "van"] {
            db.execute("INSERT INTO tokens VALUES (?1,?2)", params![hash(who), who])
                .unwrap();
        }
        db.execute(
            "INSERT INTO projects VALUES ('voice-test','Voice test','an')",
            [],
        )
        .unwrap();
        let service = Arc::new(Service {
            db: Arc::new(Mutex::new(db)),
            enabled: true,
            credential: "worker-secret".into(),
            memory: Mutex::default(),
            media: Mutex::default(),
        });
        let epoch = realtime_epoch(&service.db.lock().unwrap()).unwrap();
        service.observe("an", "human-session", "lobby", epoch);
        let lease = Lease {
            id: "lease".into(),
            agent: "mona".into(),
            epoch,
            updated: now(),
            started: now(),
            revision: 1,
            state: "ready".into(),
            message: String::new(),
        };
        service.db.lock().unwrap().execute("INSERT INTO live_agent_sessions(id,room,agent,epoch,started,state) VALUES ('lease','lobby','mona',?1,?2,'ready')",params![epoch,now()]).unwrap();
        service
            .memory
            .lock()
            .unwrap()
            .leases
            .insert("lobby".into(), lease);
        service
    }
    fn headers(token: &str) -> HeaderMap {
        let mut h = HeaderMap::new();
        h.insert("authorization", format!("Bearer {token}").parse().unwrap());
        h
    }
    fn work(id: &str, who: &str) -> Work {
        Work {
            room: "lobby".into(),
            lease: "lease".into(),
            actor: who.into(),
            id: id.into(),
            project: Some("voice-test".into()),
            title: Some("Verified voice task".into()),
        }
    }
    #[tokio::test]
    async fn mona_management_requires_the_speaker_permission_and_cannot_change_itself() {
        let s = fixture();
        let work = |target: &str| ManageWork {
            room: "lobby".into(),
            lease: "lease".into(),
            actor: "an".into(),
            id: "operation".into(),
            target: Some(target.into()),
            version: Some(1),
            changes: Some(json!({"voice":"cedar","gender":"male"})),
            action: Some("agents.configure".into()),
        };
        s.db.lock()
            .unwrap()
            .execute("DELETE FROM actor_roles WHERE actor='an'", [])
            .unwrap();
        assert!(management(
            Extension(s.clone()),
            headers("worker-secret"),
            Json(work("dev-agent"))
        )
        .await
        .is_err());
        s.db.lock()
            .unwrap()
            .execute("INSERT INTO actor_roles VALUES ('an','org-admin')", [])
            .unwrap();
        let _ = management(
            Extension(s.clone()),
            headers("worker-secret"),
            Json(work("dev-agent")),
        )
        .await
        .unwrap();
        assert_eq!(
            super::super::agent_config::load(&s.db.lock().unwrap(), "dev-agent")
                .unwrap()
                .0
                .voice,
            "cedar"
        );
        assert!(management(
            Extension(s.clone()),
            headers("worker-secret"),
            Json(work("mona"))
        )
        .await
        .is_err());
        s.leave("human-session");
        assert!(management(
            Extension(s.clone()),
            headers("worker-secret"),
            Json(work("qa-agent"))
        )
        .await
        .is_err());
    }
    #[test]
    fn configuration_revision_fences_an_existing_voice_lease() {
        let s = fixture();
        s.db.lock()
            .unwrap()
            .execute(
                "INSERT OR IGNORE INTO actor_roles VALUES ('an','org-admin')",
                [],
            )
            .unwrap();
        let mut db = s.db.lock().unwrap();
        let _ = super::super::agent_config::save(
            &mut db,
            "an",
            "mona",
            super::super::agent_config::Update {
                version: 1,
                config: super::super::agent_config::defaults("mona"),
            },
            "workspace",
        )
        .unwrap();
        assert!(s
            .validate(&db, &s.memory.lock().unwrap(), "lobby", "lease")
            .is_err());
    }
    #[test]
    fn worker_auth_and_lease_fences_fail_closed() {
        let s = fixture();
        assert!(s.worker(&headers("an")).is_err());
        assert!(s.worker(&headers("worker-secret")).is_ok());
        let db = s.db.lock().unwrap();
        let mut mem = s.memory.lock().unwrap();
        assert!(s.validate(&db, &mem, "dev", "lease").is_err());
        assert!(s.validate(&db, &mem, "lobby", "old-lease").is_err());
        assert!(s
            .requesting_actor(&db, &mem, "lobby", "lease", "van")
            .is_err());
        mem.leases.get_mut("lobby").unwrap().updated = now() - 13;
        assert!(s.validate(&db, &mem, "lobby", "lease").is_err());
    }
    #[test]
    fn empty_room_and_epoch_rotation_expire_workers() {
        let s = fixture();
        s.leave("human-session");
        assert!(s.memory.lock().unwrap().leases.is_empty());
        let s = fixture();
        s.memory
            .lock()
            .unwrap()
            .leases
            .get_mut("lobby")
            .unwrap()
            .epoch += 1;
        s.sweep();
        assert!(s.memory.lock().unwrap().leases.is_empty());
    }
    #[tokio::test]
    async fn proposal_requires_owner_approval_and_retries_create_one_task() {
        let s = fixture();
        let id = uuid::Uuid::new_v4().to_string();
        for _ in 0..2 {
            let _ = propose(
                Extension(s.clone()),
                headers("worker-secret"),
                Json(work(&id, "an")),
            )
            .await
            .unwrap();
        }
        assert_eq!(
            s.db.lock()
                .unwrap()
                .query_row("SELECT COUNT(*) FROM tasks WHERE id=?1", [&id], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            0
        );
        assert!(decide(
            State(s.db.clone()),
            Extension(s.clone()),
            headers("van"),
            Path(id.clone()),
            Json(Decision {
                action: "approve".into()
            })
        )
        .await
        .is_err());
        for _ in 0..2 {
            let _ = decide(
                State(s.db.clone()),
                Extension(s.clone()),
                headers("an"),
                Path(id.clone()),
                Json(Decision {
                    action: "approve".into(),
                }),
            )
            .await
            .unwrap();
        }
        assert_eq!(
            s.db.lock()
                .unwrap()
                .query_row("SELECT COUNT(*) FROM tasks WHERE id=?1", [&id], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            1
        );
    }
    #[tokio::test]
    async fn proposals_recheck_presence_and_operation_content() {
        let s = fixture();
        let id = uuid::Uuid::new_v4().to_string();
        let _ = propose(
            Extension(s.clone()),
            headers("worker-secret"),
            Json(work(&id, "an")),
        )
        .await
        .unwrap();
        let mut changed = work(&id, "an");
        changed.title = Some("Changed".into());
        assert!(propose(
            Extension(s.clone()),
            headers("worker-secret"),
            Json(changed)
        )
        .await
        .is_err());
        s.leave("human-session");
        assert!(decide(
            State(s.db.clone()),
            Extension(s.clone()),
            headers("an"),
            Path(id.clone()),
            Json(Decision {
                action: "approve".into()
            })
        )
        .await
        .is_err());
        assert!(propose(
            Extension(s.clone()),
            headers("worker-secret"),
            Json(work(&uuid::Uuid::new_v4().to_string(), "an"))
        )
        .await
        .is_err());
    }
    #[tokio::test]
    async fn waiting_with_a_closed_model_never_spends_duration_or_pauses_the_room() {
        let s = fixture();
        s.memory
            .lock()
            .unwrap()
            .leases
            .get_mut("lobby")
            .unwrap()
            .started = now() - 3600;
        for _ in 0..2 {
            let result = report(
                Extension(s.clone()),
                headers("worker-secret"),
                Json(Report {
                    room: "lobby".into(),
                    lease: "lease".into(),
                    state: "ready".into(),
                    message: String::new(),
                    seconds: 0.,
                    caption: None,
                    speaker: None,
                }),
            )
            .await
            .unwrap();
            assert_eq!(result.0["active"], true);
        }
        let db = s.db.lock().unwrap();
        assert_eq!(
            db.query_row(
                "SELECT seconds FROM live_agent_sessions WHERE id='lease'",
                [],
                |r| r.get::<_, f64>(0)
            )
            .unwrap(),
            0.
        );
        assert_eq!(
            db.query_row(
                "SELECT COALESCE(SUM(seconds),0) FROM live_agent_daily_usage",
                [],
                |r| r.get::<_, f64>(0)
            )
            .unwrap(),
            0.
        );
        assert!(!Service::settings(&db, "lobby").unwrap().1);
    }
    #[tokio::test]
    async fn session_cap_pauses_room_and_drops_the_lease() {
        let s = fixture();
        s.memory
            .lock()
            .unwrap()
            .leases
            .get_mut("lobby")
            .unwrap()
            .started = now() - 601;
        let result = report(
            Extension(s.clone()),
            headers("worker-secret"),
            Json(Report {
                room: "lobby".into(),
                lease: "lease".into(),
                state: "listening".into(),
                message: String::new(),
                seconds: 601.,
                caption: None,
                speaker: None,
            }),
        )
        .await
        .unwrap();
        assert_eq!(result.0["active"], false);
        assert!(s.memory.lock().unwrap().leases.is_empty());
        assert!(Service::settings(&s.db.lock().unwrap(), "lobby").unwrap().1);
    }
    #[tokio::test]
    async fn caption_fragments_merge_and_unverified_speakers_are_dropped() {
        let s = fixture();
        for (speaker, text) in [("an", "Hello"), ("an", " world"), ("van", "forged")] {
            let _ = report(
                Extension(s.clone()),
                headers("worker-secret"),
                Json(Report {
                    room: "lobby".into(),
                    lease: "lease".into(),
                    state: "listening".into(),
                    message: String::new(),
                    seconds: 0.,
                    caption: Some(text.into()),
                    speaker: Some(speaker.into()),
                }),
            )
            .await
            .unwrap();
        }
        let mem = s.memory.lock().unwrap();
        let captions = mem.captions.get("lobby").unwrap();
        assert_eq!(captions.len(), 1);
        assert_eq!(captions[0]["text"], "Hello world");
    }
    #[tokio::test]
    async fn rejecting_a_proposal_never_creates_a_task() {
        let s = fixture();
        let id = uuid::Uuid::new_v4().to_string();
        let _ = propose(
            Extension(s.clone()),
            headers("worker-secret"),
            Json(work(&id, "an")),
        )
        .await
        .unwrap();
        let _ = decide(
            State(s.db.clone()),
            Extension(s.clone()),
            headers("an"),
            Path(id.clone()),
            Json(Decision {
                action: "reject".into(),
            }),
        )
        .await
        .unwrap();
        let result = decide(
            State(s.db.clone()),
            Extension(s.clone()),
            headers("an"),
            Path(id.clone()),
            Json(Decision {
                action: "approve".into(),
            }),
        )
        .await
        .unwrap();
        assert_eq!(result.0["state"], "rejected");
        assert_eq!(
            s.db.lock()
                .unwrap()
                .query_row("SELECT COUNT(*) FROM tasks WHERE id=?1", [&id], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            0
        );
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManageWork {
    room: String,
    lease: String,
    actor: String,
    id: String,
    target: Option<String>,
    version: Option<i64>,
    changes: Option<Value>,
    action: Option<String>,
}
pub async fn management(
    Extension(s): Extension<Arc<Service>>,
    headers: HeaderMap,
    Json(body): Json<ManageWork>,
) -> Result<Json<Value>, ApiError> {
    s.worker(&headers)?;
    if body.id.is_empty() || body.id.len() > 160 {
        return Err(err(StatusCode::BAD_REQUEST, "invalid operation identifier"));
    }
    let mut db = s.db.lock().unwrap();
    let mem = s.memory.lock().unwrap();
    let lease = s.requesting_actor(&db, &mem, &body.room, &body.lease, &body.actor)?;
    if lease.agent != "mona" || !super::agent_config::can_manage(&db, &body.actor)? {
        return Err(err(
            StatusCode::FORBIDDEN,
            "Mona and an authorized administrator are required",
        ));
    }
    let action = body.action.as_deref().unwrap_or("agents.read");
    super::agent_config::allowed(&db, &lease.agent, action)?;
    let target = body.target.unwrap_or_default();
    if action.starts_with("agents.") {
        return Ok(Json(super::agent_config::delegated(
            &mut db,
            &body.actor,
            action,
            &target,
            body.version,
            body.changes.unwrap_or(json!({})),
        )?));
    }
    if !["rooms.select", "rooms.pause", "rooms.resume"].contains(&action) {
        return Err(err(StatusCode::FORBIDDEN, "unsupported management action"));
    }
    if !permitted(&db, &body.actor, &target)? || residents(&target).is_empty() {
        return Err(err(StatusCode::FORBIDDEN, "room access denied"));
    }
    let (mut selected, mut paused) = Service::settings(&db, &target)?;
    match action {
        "rooms.pause" => paused = true,
        "rooms.resume" => paused = false,
        _ => {
            let chosen = body
                .changes
                .as_ref()
                .and_then(|v| v["agent"].as_str())
                .unwrap_or("");
            if !residents(&target).contains(&chosen) {
                return Err(err(
                    StatusCode::BAD_REQUEST,
                    "agent is not resident in the target room",
                ));
            }
            selected = chosen.into();
        }
    }
    db.execute("INSERT INTO live_agent_settings VALUES (?1,?2,?3) ON CONFLICT(room) DO UPDATE SET agent=excluded.agent,paused=excluded.paused",params![target,selected,paused]).map_err(db_error)?;
    db.execute(
        "INSERT INTO security_audit(actor,subject,action,created) VALUES (?1,?2,?3,?4)",
        params![body.actor, target, format!("mona_{action}"), now()],
    )
    .map_err(db_error)?;
    Ok(Json(
        json!({"room":target,"selected":selected,"paused":paused}),
    ))
}

#[derive(Deserialize)]
pub struct VoiceAnswer {
    room: String,
    lease: String,
    actor: String,
    question: String,
    answer: String,
}
pub async fn answer_question(
    Extension(s): Extension<Arc<Service>>,
    headers: HeaderMap,
    Json(body): Json<VoiceAnswer>,
) -> Result<Json<Value>, ApiError> {
    s.worker(&headers)?;
    let mut db = s.db.lock().unwrap();
    let mem = s.memory.lock().unwrap();
    let lease = s.requesting_actor(&db, &mem, &body.room, &body.lease, &body.actor)?;
    super::agent_config::allowed(&db, &lease.agent, "tasks.propose")?;
    // A shared voice channel must never expose a private ticket.
    let public: bool=db.query_row("SELECT EXISTS(SELECT 1 FROM job_questions q JOIN agent_jobs j ON j.id=q.job JOIN tasks t ON t.id=j.task WHERE q.id=?1 AND j.created_by=?2 AND NOT EXISTS(SELECT 1 FROM project_rules WHERE project=t.project))",params![body.question,body.actor],|r|r.get(0)).map_err(db_error)?;
    if !public {
        return Err(err(StatusCode::FORBIDDEN, "use private notification reply"));
    }
    super::workflow::answer_as(
        &mut db,
        &body.actor,
        &body.question,
        super::workflow::Answer {
            body: body.answer,
            attachments: vec![],
        },
    )?;
    Ok(Json(json!({"state":"answered"})))
}

#[derive(Deserialize)]
pub struct UiWork {
    room: String,
    lease: String,
    actor: String,
    #[serde(default)]
    action: Option<Value>,
}
pub async fn operate_ui(
    Extension(s): Extension<Arc<Service>>,
    headers: HeaderMap,
    Json(body): Json<UiWork>,
) -> Result<Json<Value>, ApiError> {
    s.worker(&headers)?;
    let command_id = {
        let db = s.db.lock().unwrap();
        let mem = s.memory.lock().unwrap();
        s.requesting_actor(&db, &mem, &body.room, &body.lease, &body.actor)?;
        let users = Service::users(
            &db,
            &mem,
            &body.room,
            realtime_epoch(&db).map_err(db_error)?,
        );
        let sessions: Vec<_> = users.iter().filter(|u| u["actor"] == body.actor).collect();
        if sessions.len() != 1 {
            return Err(err(
                StatusCode::CONFLICT,
                "use one active app session for voice UI control",
            ));
        }
        let session = sessions[0]["session"].as_str().unwrap_or("");
        if let Some(action) = &body.action {
            super::ui_actions::enqueue(&db, &body.actor, session, action)?
        } else {
            return Ok(Json(
                json!({"controls":super::ui_actions::controls(&db,&body.actor,session)?}),
            ));
        }
    };
    for _ in 0..25 {
        tokio::time::sleep(Duration::from_millis(200)).await;
        let db = s.db.lock().unwrap();
        let result: Option<String> = db
            .query_row(
                "SELECT result FROM ui_commands WHERE id=?1",
                [&command_id],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_error)?
            .flatten();
        if let Some(result) = result {
            return Ok(Json(json!({"result":result})));
        }
    }
    Ok(Json(
        json!({"result":"Delivery pending; do not repeat the action or claim success."}),
    ))
}
