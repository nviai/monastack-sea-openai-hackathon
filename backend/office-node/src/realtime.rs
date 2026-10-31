//! Realtime capability: ephemeral presence, separate from the authority's
//! persistent records. It holds no database and no credentials. Every request
//! carries a short-lived ticket signed by the authority, listing the rooms the
//! actor may enter when it was issued and the authority's access epoch.
//!
//! The authority increments the epoch whenever room membership or a
//! credential changes. Tickets and presence entries from an older epoch are
//! rejected or hidden as soon as the realtime service observes the new epoch,
//! so revocation does not wait for ticket expiry. If the epoch cannot be
//! confirmed recently, the service fails closed.
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

pub const TICKET_VERSION: u32 = 1;
/// Tickets are refreshed by clients well before this.
pub const TICKET_SECONDS: i64 = 30;
/// Presence without a heartbeat for this long is removed.
pub const PRESENCE_SECONDS: i64 = 20;
/// Without a fresh epoch observation, the service refuses all requests.
pub const EPOCH_STALE_SECONDS: i64 = 10;

type HmacSha256 = Hmac<Sha256>;

/// 32-byte shared secret between the authority and realtime services.
#[derive(Clone)]
pub struct TicketKey(Arc<[u8; 32]>);

impl TicketKey {
    pub fn random() -> Self {
        let mut key = [0u8; 32];
        for chunk in key.chunks_mut(16) {
            chunk.copy_from_slice(uuid::Uuid::new_v4().as_bytes());
        }
        TicketKey(Arc::new(key))
    }
    pub fn from_hex(text: &str) -> Result<Self, &'static str> {
        let bytes = hex::decode(text.trim()).map_err(|_| "realtime key must be hex")?;
        let key: [u8; 32] = bytes
            .try_into()
            .map_err(|_| "realtime key must be 32 bytes")?;
        Ok(TicketKey(Arc::new(key)))
    }
    pub fn from_env() -> Result<Option<Self>, Box<dyn std::error::Error>> {
        match std::env::var("MONASTACK_REALTIME_KEY_FILE") {
            Ok(path) => Ok(Some(Self::from_hex(&std::fs::read_to_string(path)?)?)),
            Err(_) => Ok(None),
        }
    }
    fn mac(&self, payload: &[u8]) -> HmacSha256 {
        let mut mac = HmacSha256::new_from_slice(&self.0[..]).expect("any key length");
        mac.update(b"monastack-realtime-ticket-v1\0");
        mac.update(payload);
        mac
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ticket {
    pub v: u32,
    pub actor: String,
    pub rooms: Vec<String>,
    pub epoch: u64,
    pub iat: i64,
    pub exp: i64,
}

pub fn sign(key: &TicketKey, ticket: &Ticket) -> String {
    let payload = serde_json::to_vec(ticket).expect("ticket serializes");
    let tag = key.mac(&payload).finalize().into_bytes();
    format!("{}.{}", hex::encode(payload), hex::encode(tag))
}

pub fn verify(key: &TicketKey, text: &str, now: i64) -> Result<Ticket, &'static str> {
    let (payload, tag) = text.split_once('.').ok_or("malformed ticket")?;
    if payload.len() > 8192 {
        return Err("malformed ticket");
    }
    let payload = hex::decode(payload).map_err(|_| "malformed ticket")?;
    let tag = hex::decode(tag).map_err(|_| "malformed ticket")?;
    key.mac(&payload)
        .verify_slice(&tag)
        .map_err(|_| "invalid ticket")?;
    let ticket: Ticket = serde_json::from_slice(&payload).map_err(|_| "malformed ticket")?;
    if ticket.v != TICKET_VERSION || ticket.iat > now + 5 || ticket.exp <= now {
        return Err("expired ticket");
    }
    Ok(ticket)
}

/// Where the realtime service learns the authority's current access epoch.
pub trait EpochSource: Send + Sync {
    /// The current epoch, or `None` when it cannot be confirmed.
    fn current(&self) -> Option<u64>;
}

/// Epoch observed by polling a separately running authority.
pub struct PolledEpoch {
    value: Mutex<Option<(u64, i64)>>,
}

impl PolledEpoch {
    pub fn new() -> Arc<Self> {
        Arc::new(PolledEpoch {
            value: Mutex::new(None),
        })
    }
    pub fn observe(&self, epoch: u64) {
        *self.value.lock().unwrap() = Some((epoch, crate::now()));
    }
}

impl EpochSource for PolledEpoch {
    fn current(&self) -> Option<u64> {
        let value = *self.value.lock().unwrap();
        value
            .filter(|(_, seen)| crate::now() - seen <= EPOCH_STALE_SECONDS)
            .map(|(epoch, _)| epoch)
    }
}

/// Minimal HTTP/1.1 client for loopback control traffic (authority epoch,
/// media server API). Returns the status and body, or `None` on failure.
pub async fn http_request(
    addr: std::net::SocketAddr,
    method: &str,
    path: &str,
    headers: &[(&str, &str)],
    body: Option<&[u8]>,
) -> Option<(u16, Vec<u8>)> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let exchange = async {
        let mut stream = tokio::net::TcpStream::connect(addr).await.ok()?;
        let mut request =
            format!("{method} {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n");
        for (name, value) in headers {
            request.push_str(&format!("{name}: {value}\r\n"));
        }
        let body = body.unwrap_or_default();
        request.push_str(&format!("Content-Length: {}\r\n\r\n", body.len()));
        stream.write_all(request.as_bytes()).await.ok()?;
        stream.write_all(body).await.ok()?;
        let mut response = Vec::new();
        stream.read_to_end(&mut response).await.ok()?;
        let split = response.windows(4).position(|w| w == b"\r\n\r\n")?;
        let head = std::str::from_utf8(&response[..split]).ok()?;
        let status = head.split_whitespace().nth(1)?.parse().ok()?;
        let mut payload = response[split + 4..].to_vec();
        if head.lines().any(|l| {
            l.to_ascii_lowercase()
                .starts_with("transfer-encoding: chunked")
        }) {
            payload = dechunk(&payload)?;
        }
        Some((status, payload))
    };
    tokio::time::timeout(std::time::Duration::from_secs(3), exchange)
        .await
        .ok()
        .flatten()
}

fn dechunk(mut data: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    loop {
        let line = data.windows(2).position(|w| w == b"\r\n")?;
        let size =
            usize::from_str_radix(std::str::from_utf8(&data[..line]).ok()?.trim(), 16).ok()?;
        data = &data[line + 2..];
        if size == 0 {
            return Some(out);
        }
        out.extend_from_slice(data.get(..size)?);
        data = data.get(size + 2..)?;
    }
}

/// Polls `GET /v1/realtime/epoch` on a loopback authority once per second.
pub async fn poll_epoch(authority: std::net::SocketAddr, epoch: Arc<PolledEpoch>) {
    loop {
        if let Some((200, body)) =
            http_request(authority, "GET", "/v1/realtime/epoch", &[], None).await
        {
            if let Some(value) = serde_json::from_slice::<serde_json::Value>(&body)
                .ok()
                .and_then(|v| v.get("epoch")?.as_u64())
            {
                epoch.observe(value);
            }
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    }
}

struct Session {
    actor: String,
    room: String,
    x: f64,
    y: f64,
    seq: i64,
    epoch: u64,
    updated: i64,
}

#[derive(Clone)]
pub struct Realtime {
    key: TicketKey,
    epoch: Arc<dyn EpochSource>,
    sessions: Arc<Mutex<HashMap<String, Session>>>,
    map: &'static monastack_core::map::Map,
    media: Option<Arc<crate::media::MediaControl>>,
}

impl Realtime {
    pub fn new(key: TicketKey, epoch: Arc<dyn EpochSource>) -> Self {
        Realtime {
            key,
            epoch,
            sessions: Arc::default(),
            map: crate::office_map(),
            media: None,
        }
    }

    /// Enables voice: starts the media control plane against this epoch.
    pub fn with_media(mut self, media: Arc<crate::media::MediaControl>) -> Self {
        tokio::spawn(media.clone().run(self.epoch.clone()));
        self.media = Some(media);
        self
    }

    /// Drops expired sessions and removes their media participants.
    fn expire(&self, sessions: &mut HashMap<String, Session>, now: i64) {
        sessions.retain(|id, s| {
            let live = now - s.updated <= PRESENCE_SECONDS;
            if !live {
                if let Some(media) = &self.media {
                    media.remove(id);
                }
            }
            live
        });
    }

    fn authorize(&self, headers: &HeaderMap) -> Result<(Ticket, u64), crate::ApiError> {
        let current = self.epoch.current().ok_or(crate::err(
            StatusCode::SERVICE_UNAVAILABLE,
            "authority epoch unavailable",
        ))?;
        let text = headers
            .get("authorization")
            .and_then(|h| h.to_str().ok())
            .and_then(|h| h.strip_prefix("Ticket "))
            .ok_or(crate::err(StatusCode::UNAUTHORIZED, "ticket required"))?;
        let ticket = verify(&self.key, text, crate::now())
            .map_err(|e| crate::err(StatusCode::UNAUTHORIZED, e))?;
        if ticket.epoch < current {
            return Err(crate::err(StatusCode::UNAUTHORIZED, "stale ticket"));
        }
        Ok((ticket, current))
    }
}

#[derive(Deserialize)]
pub struct UpdatePresence {
    pub session: String,
    pub room: String,
    pub x: f64,
    pub y: f64,
    pub seq: i64,
}

#[derive(Debug, Serialize)]
pub struct Presence {
    pub session: String,
    pub actor: String,
    pub room: String,
    pub x: f64,
    pub y: f64,
    pub seq: i64,
}

pub async fn update_presence(
    State(rt): State<Realtime>,
    headers: HeaderMap,
    Json(p): Json<UpdatePresence>,
) -> Result<StatusCode, crate::ApiError> {
    let (ticket, epoch) = rt.authorize(&headers)?;
    if p.session.len() < 16
        || p.session.len() > 80
        || !p.x.is_finite()
        || !p.y.is_finite()
        || p.x.fract() != 0.0
        || p.y.fract() != 0.0
        || p.x.abs() > 10000.
        || p.y.abs() > 10000.
        || p.seq < 0
    {
        return Err(crate::err(StatusCode::BAD_REQUEST, "invalid presence"));
    }
    if !ticket.rooms.contains(&p.room) {
        return Err(crate::err(StatusCode::FORBIDDEN, "room access denied"));
    }
    let point = [p.x as i32, p.y as i32];
    let allowed = ticket.rooms.iter().cloned().collect();
    let actual_room = rt
        .map
        .room_at(point)
        .map(|r| r.id.as_str())
        .unwrap_or(crate::CORRIDOR_ROOM);
    if !rt.map.walkable(point, &allowed) || actual_room != p.room {
        return Err(crate::err(
            StatusCode::FORBIDDEN,
            "invalid or unauthorized position",
        ));
    }
    let now = crate::now();
    let mut sessions = rt.sessions.lock().unwrap();
    rt.expire(&mut sessions, now);
    if let Some(old) = sessions.get(&p.session) {
        if old.actor != ticket.actor || p.seq <= old.seq {
            return Err(crate::err(
                StatusCode::CONFLICT,
                "stale sequence or session",
            ));
        }
        // Leaving a room ends that room's voice for this session.
        if old.room != p.room {
            if let Some(media) = &rt.media {
                media.remove(&p.session);
            }
        }
    }
    if !sessions.contains_key(&p.session) && sessions.len() >= 10_000 {
        return Err(crate::err(StatusCode::SERVICE_UNAVAILABLE, "presence full"));
    }
    sessions.insert(
        p.session,
        Session {
            actor: ticket.actor,
            room: p.room,
            x: p.x,
            y: p.y,
            seq: p.seq,
            epoch,
            updated: now,
        },
    );
    Ok(StatusCode::NO_CONTENT)
}

pub async fn presence(
    State(rt): State<Realtime>,
    headers: HeaderMap,
) -> Result<Json<Vec<Presence>>, crate::ApiError> {
    let (ticket, epoch) = rt.authorize(&headers)?;
    let now = crate::now();
    let sessions = rt.sessions.lock().unwrap();
    Ok(Json(
        sessions
            .iter()
            .filter(|(_, s)| {
                now - s.updated <= PRESENCE_SECONDS
                    // Entries written before the latest access change are
                    // hidden until their owner re-publishes with a new ticket.
                    && s.epoch >= epoch
                    && ticket.rooms.contains(&s.room)
            })
            .map(|(session, s)| Presence {
                session: session.clone(),
                actor: s.actor.clone(),
                room: s.room.clone(),
                x: s.x,
                y: s.y,
                seq: s.seq,
            })
            .collect(),
    ))
}

pub async fn leave_presence(
    State(rt): State<Realtime>,
    Path(session): Path<String>,
    headers: HeaderMap,
) -> Result<StatusCode, crate::ApiError> {
    let (ticket, _) = rt.authorize(&headers)?;
    let mut sessions = rt.sessions.lock().unwrap();
    if sessions
        .get(&session)
        .is_some_and(|s| s.actor == ticket.actor)
    {
        sessions.remove(&session);
        if let Some(media) = &rt.media {
            media.remove(&session);
        }
    }
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct MediaRequest {
    pub room: String,
    pub session: String,
}

#[derive(Serialize)]
pub struct MediaGrant {
    pub url: String,
    pub token: String,
    pub room: String,
    pub identity: String,
    pub expires_in: i64,
}

/// Issues a voice join token for the room the caller is currently in.
pub async fn media_token(
    State(rt): State<Realtime>,
    headers: HeaderMap,
    Json(request): Json<MediaRequest>,
) -> Result<Json<MediaGrant>, crate::ApiError> {
    let (ticket, epoch) = rt.authorize(&headers)?;
    let media = rt.media.clone().ok_or(crate::err(
        StatusCode::SERVICE_UNAVAILABLE,
        "voice unavailable",
    ))?;
    if !ticket.rooms.contains(&request.room) {
        return Err(crate::err(StatusCode::FORBIDDEN, "room access denied"));
    }
    let present = {
        let now = crate::now();
        let sessions = rt.sessions.lock().unwrap();
        sessions.get(&request.session).is_some_and(|s| {
            s.actor == ticket.actor
                && s.room == request.room
                && s.epoch >= epoch
                && now - s.updated <= PRESENCE_SECONDS
        })
    };
    if !present {
        return Err(crate::err(
            StatusCode::CONFLICT,
            "enter the room before joining voice",
        ));
    }
    let issued = media
        .issue(&request.room, &ticket.actor, &request.session, epoch)
        .await?;
    Ok(Json(MediaGrant {
        url: media.config.client_url.clone(),
        token: issued.token,
        room: issued.room,
        identity: issued.identity,
        expires_in: crate::media::TOKEN_SECONDS,
    }))
}

pub async fn media_status(State(rt): State<Realtime>) -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "available": rt.media.as_ref().is_some_and(|m| m.ready()),
    }))
}

pub async fn health(State(rt): State<Realtime>) -> Result<StatusCode, crate::ApiError> {
    rt.epoch
        .current()
        .map(|_| StatusCode::NO_CONTENT)
        .ok_or(crate::err(
            StatusCode::SERVICE_UNAVAILABLE,
            "authority epoch unavailable",
        ))
}

pub fn router(rt: Realtime) -> axum::Router {
    use axum::routing::{delete, get};
    axum::Router::new()
        .route("/v1/presence", get(presence).post(update_presence))
        .route("/v1/presence/{session}", delete(leave_presence))
        .route("/v1/realtime/health", get(health))
        .route("/v1/media/token", axum::routing::post(media_token))
        .route("/v1/media/status", get(media_status))
        .with_state(rt)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ticket(epoch: u64, exp: i64) -> Ticket {
        Ticket {
            v: TICKET_VERSION,
            actor: "an".into(),
            rooms: vec!["lobby".into()],
            epoch,
            iat: 1000,
            exp,
        }
    }

    #[test]
    fn tickets_are_authenticated_and_expire() {
        let key = TicketKey::random();
        let signed = sign(&key, &ticket(1, 1030));
        assert_eq!(verify(&key, &signed, 1001), Ok(ticket(1, 1030)));
        assert_eq!(verify(&key, &signed, 1030), Err("expired ticket"));
        assert_eq!(
            verify(&TicketKey::random(), &signed, 1001),
            Err("invalid ticket")
        );
        // Changing the payload (e.g. adding a room) breaks the signature.
        let forged = sign(&key, &ticket(1, 1030)).replacen(
            &hex::encode(br#""rooms":["lobby"]"#),
            &hex::encode(br#""rooms":["hr123"]"#),
            1,
        );
        assert!(verify(&key, &forged, 1001).is_err());
        assert_eq!(verify(&key, "nonsense", 1001), Err("malformed ticket"));
    }

    #[test]
    fn keys_must_be_32_hex_bytes() {
        assert!(TicketKey::from_hex(&"ab".repeat(32)).is_ok());
        assert!(TicketKey::from_hex("abcd").is_err());
        assert!(TicketKey::from_hex(&"zz".repeat(32)).is_err());
    }

    #[test]
    fn stale_epoch_observations_fail_closed() {
        let epoch = PolledEpoch::new();
        assert_eq!(epoch.current(), None);
        epoch.observe(4);
        assert_eq!(epoch.current(), Some(4));
        *epoch.value.lock().unwrap() = Some((4, crate::now() - EPOCH_STALE_SECONDS - 1));
        assert_eq!(epoch.current(), None);
    }
}
