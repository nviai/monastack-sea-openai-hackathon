//! Media control plane for a self-hosted LiveKit server, part of the realtime
//! capability. It never forwards audio; it decides who may join which media
//! room and removes access when authorization changes.
//!
//! Revocation design. Self-hosted LiveKit cannot invalidate an issued token,
//! so tokens are never the boundary on their own:
//! - the server runs with `room.auto_create: false`, so a token can only join
//!   a media room this control plane created;
//! - each Monastack room maps to one media room per `MediaGate` generation;
//! - when the authority's access epoch advances (membership or credential
//!   change) the current media room is deleted, which disconnects everyone in
//!   it and makes every token for it useless, before any new room is created;
//! - tokens are only issued to an actor whose ticket lists the room and whose
//!   live presence session is in that room, and expire after two minutes.
//!
//! Leaving a room removes the participant, but an actor who is still a member
//! can rejoin with an unexpired token; that is not an authorization breach.
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use axum::http::StatusCode;
use base64::Engine;
use hmac::{Hmac, Mac};
use monastack_core::media::{MediaGate, Phase};
use serde_json::{json, Value};
use sha2::Sha256;

use crate::realtime::EpochSource;

/// Lifetime of a join token; it only needs to outlive the connection attempt.
pub const TOKEN_SECONDS: i64 = 120;
const PREFIX: &str = "mona-";

pub struct MediaConfig {
    /// WebSocket URL handed to clients, e.g. `ws://127.0.0.1:7880`.
    pub client_url: String,
    api: SocketAddr,
    key: String,
    secret: Vec<u8>,
}

impl MediaConfig {
    /// Reads `MONASTACK_MEDIA_URL` and `MONASTACK_MEDIA_KEY_FILE` (one line:
    /// `API_KEY SECRET`). Voice is unavailable when either is missing.
    pub fn from_env() -> Result<Option<Self>, Box<dyn std::error::Error>> {
        let (Ok(url), Ok(path)) = (
            std::env::var("MONASTACK_MEDIA_URL"),
            std::env::var("MONASTACK_MEDIA_KEY_FILE"),
        ) else {
            return Ok(None);
        };
        let api: SocketAddr = url
            .strip_prefix("ws://")
            .filter(|rest| rest.starts_with("127.0.0.1:") && !rest.contains('/'))
            .ok_or("MONASTACK_MEDIA_URL must be ws://127.0.0.1:PORT")?
            .parse()?;
        let text = std::fs::read_to_string(path)?;
        let (key, secret) = text
            .trim()
            .split_once(char::is_whitespace)
            .ok_or("media key file must contain `API_KEY SECRET`")?;
        if key.is_empty() || secret.trim().len() < 32 {
            return Err("media secret must be at least 32 characters".into());
        }
        Ok(Some(MediaConfig {
            client_url: super::runtime_paths::advertised_url(
                &std::env::var("MONASTACK_MEDIA_PUBLIC_URL").unwrap_or(url),
                "ws",
            )?,
            api,
            key: key.to_owned(),
            secret: secret.trim().as_bytes().to_vec(),
        }))
    }

    fn jwt(&self, claims: Value) -> String {
        let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let header = b64.encode(br#"{"alg":"HS256","typ":"JWT"}"#);
        let payload = b64.encode(claims.to_string());
        let mut mac = Hmac::<Sha256>::new_from_slice(&self.secret).expect("any key length");
        mac.update(format!("{header}.{payload}").as_bytes());
        let signature = b64.encode(mac.finalize().into_bytes());
        format!("{header}.{payload}.{signature}")
    }

    fn admin_token(&self, room: Option<&str>) -> String {
        let mut video = json!({"roomCreate": true, "roomList": true});
        if let Some(room) = room {
            video["roomAdmin"] = json!(true);
            video["room"] = json!(room);
        }
        let now = crate::now();
        self.jwt(json!({"iss": self.key, "nbf": now - 5, "exp": now + 60, "video": video}))
    }

    /// Join token: microphone audio and camera video, no data channel, one
    /// media room. Both start off in the client; the server only bounds what
    /// may be published.
    pub fn join_token(&self, room: &str, identity: &str, actor: &str) -> String {
        self.join_scoped_token(room, identity, actor, false)
    }
    fn join_scoped_token(&self, room: &str, identity: &str, actor: &str, agent: bool) -> String {
        let now = crate::now();
        self.jwt(json!({
            "iss": self.key,
            "sub": identity,
            "name": actor,
            "nbf": now - 5,
            "exp": now + TOKEN_SECONDS,
            "video": {
                "room": room,
                "roomJoin": true,
                "canSubscribe": true,
                "canPublish": true,
                "canPublishData": false,
                "canPublishSources": if agent { vec!["microphone"] } else { vec!["microphone", "camera"] },
            },
        }))
    }

    async fn rpc(&self, method: &str, body: Value, room: Option<&str>) -> Result<Value, ()> {
        let token = self.admin_token(room);
        let body = body.to_string();
        let (status, response) = crate::realtime::http_request(
            self.api,
            "POST",
            &format!("/twirp/livekit.RoomService/{method}"),
            &[
                ("Authorization", &format!("Bearer {token}")),
                ("Content-Type", "application/json"),
            ],
            Some(body.as_bytes()),
        )
        .await
        .ok_or(())?;
        match status {
            200 => serde_json::from_slice(&response).map_err(|_| ()),
            // Twirp reports a missing room or participant as not_found.
            404 if method != "CreateRoom" => Ok(Value::Null),
            _ => Err(()),
        }
    }
}

#[derive(Default)]
struct RoomMedia {
    gate: MediaGate,
    /// Access epoch the current generation was created for.
    epoch: u64,
    /// Media room that may exist on the server for this Monastack room.
    name: Option<String>,
}

pub struct Issued {
    pub token: String,
    pub room: String,
    pub identity: String,
}

pub struct MediaControl {
    pub config: MediaConfig,
    ready: AtomicBool,
    rooms: tokio::sync::Mutex<HashMap<String, RoomMedia>>,
    /// Presence session → (media room, identity) for removal on room exit.
    participants: Mutex<HashMap<String, (String, String)>>,
}

impl MediaControl {
    pub fn new(config: MediaConfig) -> Arc<Self> {
        Arc::new(MediaControl {
            config,
            ready: AtomicBool::new(false),
            rooms: Default::default(),
            participants: Default::default(),
        })
    }

    pub fn client_url(&self) -> String {
        self.config.client_url.clone()
    }

    pub fn ready(&self) -> bool {
        self.ready.load(Ordering::SeqCst)
    }

    /// Deletes media rooms left by an earlier run, then watches the access
    /// epoch. Nothing is issued until the clean-up has succeeded.
    pub async fn run(self: Arc<Self>, epoch: Arc<dyn EpochSource>) {
        while !self.ready() {
            if self.clear_stale_rooms().await.is_ok() {
                self.ready.store(true, Ordering::SeqCst);
            } else {
                tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            }
        }
        loop {
            if let Some(current) = epoch.current() {
                self.stop_outdated(current).await;
            }
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        }
    }

    async fn clear_stale_rooms(&self) -> Result<(), ()> {
        let list = self.config.rpc("ListRooms", json!({}), None).await?;
        for room in list["rooms"].as_array().into_iter().flatten() {
            if let Some(name) = room["name"].as_str().filter(|n| n.starts_with(PREFIX)) {
                self.config
                    .rpc("DeleteRoom", json!({"room": name}), None)
                    .await?;
            }
        }
        Ok(())
    }

    /// Deletes every media room created before the current access epoch.
    async fn stop_outdated(&self, current: u64) {
        let mut rooms = self.rooms.lock().await;
        for media in rooms.values_mut() {
            if media.epoch < current && media.gate.phase() != Phase::Starting {
                let _ = self.stop(media, current).await;
            }
        }
    }

    /// Begins a rotation and confirms the previous media room is gone.
    async fn stop(&self, media: &mut RoomMedia, epoch: u64) -> Result<u64, ()> {
        let generation = media.gate.begin_rotation().map_err(|_| ())?;
        if let Some(old) = media.name.clone() {
            if self
                .config
                .rpc("DeleteRoom", json!({"room": old}), None)
                .await
                .is_err()
            {
                let _ = media.gate.fail(generation);
                return Err(());
            }
            media.name = None;
            self.participants
                .lock()
                .unwrap()
                .retain(|_, (r, _)| *r != old);
        }
        media.gate.confirm_stopped(generation).map_err(|_| ())?;
        media.epoch = epoch;
        Ok(generation)
    }

    /// Issues a join token for an actor already authorized by a current
    /// ticket and present in `room`.
    pub async fn issue(
        &self,
        room: &str,
        actor: &str,
        session: &str,
        epoch: u64,
    ) -> Result<Issued, crate::ApiError> {
        self.issue_scoped(room, actor, session, epoch, false).await
    }
    pub async fn issue_agent(
        &self,
        room: &str,
        actor: &str,
        session: &str,
        epoch: u64,
    ) -> Result<Issued, crate::ApiError> {
        self.issue_scoped(room, actor, session, epoch, true).await
    }
    async fn issue_scoped(
        &self,
        room: &str,
        actor: &str,
        session: &str,
        epoch: u64,
        agent: bool,
    ) -> Result<Issued, crate::ApiError> {
        let unavailable = || crate::err(StatusCode::SERVICE_UNAVAILABLE, "voice unavailable");
        if !self.ready() {
            return Err(unavailable());
        }
        let mut rooms = self.rooms.lock().await;
        let media = rooms.entry(room.to_owned()).or_default();
        let generation = match media.gate.phase() {
            Phase::Active if media.epoch == epoch => media.gate.generation(),
            Phase::Starting if media.epoch == epoch && media.name.is_none() => {
                self.start(media, room).await.map_err(|_| unavailable())?
            }
            _ => {
                self.stop(media, epoch).await.map_err(|_| unavailable())?;
                self.start(media, room).await.map_err(|_| unavailable())?
            }
        };
        media
            .gate
            .admit(generation, actor)
            .map_err(|_| unavailable())?;
        if !media.gate.may_issue(generation, actor, true) {
            return Err(unavailable());
        }
        let name = media.name.clone().ok_or_else(unavailable)?;
        let identity = format!("{actor}.{}", &session[..12.min(session.len())]);
        let token = if agent {
            self.config.join_scoped_token(&name, &identity, actor, true)
        } else {
            self.config.join_token(&name, &identity, actor)
        };
        self.participants
            .lock()
            .unwrap()
            .insert(session.to_owned(), (name.clone(), identity.clone()));
        Ok(Issued {
            token,
            room: name,
            identity,
        })
    }

    async fn start(&self, media: &mut RoomMedia, room: &str) -> Result<u64, ()> {
        let generation = media.gate.generation();
        let name = format!("{PREFIX}{room}-{}-{generation}", media.epoch);
        let created = self
            .config
            .rpc(
                "CreateRoom",
                json!({"name": name, "empty_timeout": 600, "max_participants": 50}),
                None,
            )
            .await;
        if created.is_err() || media.gate.activate(generation, Default::default()).is_err() {
            let _ = media.gate.fail(generation);
            return Err(());
        }
        media.name = Some(name);
        Ok(generation)
    }

    /// Removes a presence session's participant after it left the room.
    pub fn remove(self: &Arc<Self>, session: &str) {
        let Some((room, identity)) = self.participants.lock().unwrap().remove(session) else {
            return;
        };
        let control = self.clone();
        tokio::spawn(async move {
            let _ = control
                .config
                .rpc(
                    "RemoveParticipant",
                    json!({"room": room, "identity": identity}),
                    Some(&room),
                )
                .await;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> MediaConfig {
        MediaConfig {
            client_url: "ws://127.0.0.1:7880".into(),
            api: "127.0.0.1:7880".parse().unwrap(),
            key: "devkey".into(),
            secret: b"0123456789abcdef0123456789abcdef".to_vec(),
        }
    }

    fn claims(token: &str) -> Value {
        let parts: Vec<_> = token.split('.').collect();
        assert_eq!(parts.len(), 3);
        let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(parts[1])
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    #[test]
    fn join_tokens_are_scoped_to_one_room_microphone_and_camera() {
        let token = config().join_token("mona-lobby-0-1", "an.0123456789ab", "an");
        let c = claims(&token);
        assert_eq!(c["iss"], "devkey");
        assert_eq!(c["sub"], "an.0123456789ab");
        assert_eq!(c["video"]["room"], "mona-lobby-0-1");
        assert_eq!(c["video"]["roomJoin"], true);
        assert_eq!(c["video"]["canPublishData"], false);
        assert_eq!(
            c["video"]["canPublishSources"],
            json!(["microphone", "camera"])
        );
        assert!(c["video"].get("roomAdmin").is_none());
        assert!(c["exp"].as_i64().unwrap() - crate::now() <= TOKEN_SECONDS);
        // The signature covers header and claims.
        let parts: Vec<_> = token.split('.').collect();
        let mut mac = Hmac::<Sha256>::new_from_slice(b"0123456789abcdef0123456789abcdef").unwrap();
        mac.update(format!("{}.{}", parts[0], parts[1]).as_bytes());
        let expected =
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes());
        assert_eq!(parts[2], expected);
    }

    #[test]
    fn admin_tokens_are_short_and_room_bound_for_removal() {
        let c = claims(&config().admin_token(Some("mona-hr-2-3")));
        assert_eq!(c["video"]["roomAdmin"], true);
        assert_eq!(c["video"]["room"], "mona-hr-2-3");
        assert!(c["exp"].as_i64().unwrap() - crate::now() <= 60);
    }
}
