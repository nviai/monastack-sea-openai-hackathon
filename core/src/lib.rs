pub mod access;
pub mod documents;
pub mod jobs;
pub mod map;
pub mod media;
pub mod outbox;
pub mod tasks;
// Local prototype domain. This is not a network authorization boundary.
use serde::{Deserialize, Serialize};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

#[derive(Deserialize)]
struct Seed {
    version: u32,
    workspace: Workspace,
    actors: Vec<Actor>,
    rooms: Vec<Room>,
}
#[derive(Deserialize)]
struct Workspace {
    id: String,
}
#[derive(Deserialize)]
struct Actor {
    id: String,
    kind: String,
}
#[derive(Deserialize)]
struct Room {
    id: String,
    restricted: bool,
    members: Vec<String>,
}
#[derive(Serialize)]
struct Response {
    ok: bool,
    error: Option<String>,
}

/// Authoritative policy primitive shared by local and server adapters.
/// The caller must obtain all arguments from trusted state and authenticate the actor.
pub fn may_enter(
    tenant_matches: bool,
    human_member: bool,
    restricted: bool,
    room_member: bool,
) -> bool {
    tenant_matches && human_member && (!restricted || room_member)
}

fn allowed(seed: &Seed, tenant: &str, actor: &str, room: &str) -> bool {
    if seed.version != 1 || seed.workspace.id != tenant {
        return false;
    }
    let Some(person) = seed
        .actors
        .iter()
        .find(|p| p.id == actor && p.kind == "human")
    else {
        return false;
    };
    let Some(room) = seed.rooms.iter().find(|r| r.id == room) else {
        return false;
    };
    may_enter(
        true,
        true,
        room.restricted,
        room.members.contains(&person.id),
    )
}

#[derive(Deserialize)]
struct Request {
    seed: serde_json::Value,
    tenant: String,
    actor: String,
    room: String,
}
fn evaluate(input: &str) -> Response {
    match serde_json::from_str::<Request>(input).and_then(|r| {
        let seed: Seed = serde_json::from_value(r.seed)?;
        Ok(allowed(&seed, &r.tenant, &r.actor, &r.room))
    }) {
        Ok(true) => Response {
            ok: true,
            error: None,
        },
        Ok(false) => Response {
            ok: false,
            error: Some("Access denied".into()),
        },
        Err(_) => Response {
            ok: false,
            error: Some("Invalid request".into()),
        },
    }
}
/// Caller must provide a valid, NUL-terminated UTF-8 pointer and free the result.
#[no_mangle]
pub unsafe extern "C" fn monastack_policy_v1(input: *const c_char) -> *mut c_char {
    if input.is_null() {
        return std::ptr::null_mut();
    }
    let result = match CStr::from_ptr(input).to_str() {
        Ok(s) => evaluate(s),
        Err(_) => Response {
            ok: false,
            error: Some("Invalid UTF-8".into()),
        },
    };
    CString::new(serde_json::to_string(&result).unwrap())
        .unwrap()
        .into_raw()
}
/// Release a pointer returned by monastack_policy_v1 exactly once.
#[no_mangle]
pub unsafe extern "C" fn monastack_free_v1(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn seed() -> Seed {
        serde_json::from_str(include_str!("../../data/seed/nviai/seed.v1.json")).unwrap()
    }
    #[test]
    fn seed_has_unique_valid_references() {
        let s = seed();
        assert_eq!(s.actors.iter().filter(|a| a.kind == "human").count(), 11);
        assert_eq!(s.actors.iter().filter(|a| a.kind == "agent").count(), 6);
        let ids: std::collections::HashSet<_> = s.actors.iter().map(|a| &a.id).collect();
        assert_eq!(ids.len(), s.actors.len());
        assert!(s
            .rooms
            .iter()
            .flat_map(|r| &r.members)
            .all(|id| ids.contains(id)));
        assert_eq!(
            s.rooms
                .iter()
                .map(|r| &r.id)
                .collect::<std::collections::HashSet<_>>()
                .len(),
            s.rooms.len()
        );
    }
    #[test]
    fn restricted_default_deny_and_tenant_isolation() {
        let s = seed();
        assert!(allowed(&s, "nviai", "van", "finance"));
        assert!(!allowed(&s, "nviai", "an", "finance"));
        assert!(!allowed(&s, "nviai", "van", "hr"));
        assert!(!allowed(&s, "other", "van", "finance"));
        assert!(!allowed(&s, "nviai", "mona", "lobby"));
        assert!(!allowed(&s, "nviai", "van", "missing"));
        assert!(allowed(&s, "nviai", "van", "lobby"));
    }
    #[test]
    fn malformed_requests_fail_closed() {
        assert!(!evaluate("{}").ok);
    }
}

#[derive(Deserialize)]
struct PathRequest {
    seed: serde_json::Value,
    actor: String,
    start: [i32; 2],
    goal: [i32; 2],
    allowed_rooms: Option<Vec<String>>,
}
#[derive(Serialize)]
struct PathResponse {
    path: Option<Vec<[i32; 2]>>,
    error: Option<&'static str>,
}
fn evaluate_path(input: &str) -> PathResponse {
    let result = (|| -> Result<Option<Vec<[i32; 2]>>, &'static str> {
        let request: PathRequest = serde_json::from_str(input).map_err(|_| "Invalid request")?;
        let seed: Seed = serde_json::from_value(request.seed).map_err(|_| "Invalid seed")?;
        static WORLD: std::sync::OnceLock<Result<map::Map, &'static str>> =
            std::sync::OnceLock::new();
        let world = WORLD
            .get_or_init(|| {
                let world: map::Map =
                    serde_json::from_str(include_str!("../../data/seed/nviai/map.v1.json"))
                        .map_err(|_| "Invalid map")?;
                world.validate().map_err(|_| "Invalid map")?;
                Ok(world)
            })
            .as_ref()
            .map_err(|_| "Invalid map")?;
        // The connected node is the source of current membership. The local
        // seed remains the fallback for a disconnected preview, and the node
        // independently authorizes every network operation.
        let known_human = seed.version == 1
            && seed.workspace.id == "nviai"
            && seed
                .actors
                .iter()
                .any(|actor| actor.id == request.actor && actor.kind == "human");
        let permitted = seed
            .rooms
            .iter()
            .filter(|room| {
                known_human
                    && request.allowed_rooms.as_ref().map_or_else(
                        || allowed(&seed, "nviai", &request.actor, &room.id),
                        |rooms| rooms.contains(&room.id),
                    )
            })
            .map(|room| room.id.clone())
            .collect();
        Ok(world.path(request.start, request.goal, &permitted))
    })();
    match result {
        Ok(Some(path)) => PathResponse {
            path: Some(path),
            error: None,
        },
        Ok(None) => PathResponse {
            path: None,
            error: Some("Destination inaccessible"),
        },
        Err(error) => PathResponse {
            path: None,
            error: Some(error),
        },
    }
}
/// Caller provides a NUL-terminated UTF-8 request and frees the returned buffer.
#[no_mangle]
pub unsafe extern "C" fn monastack_path_v1(input: *const c_char) -> *mut c_char {
    if input.is_null() {
        return std::ptr::null_mut();
    }
    let response = match CStr::from_ptr(input).to_str() {
        Ok(value) => evaluate_path(value),
        Err(_) => PathResponse {
            path: None,
            error: Some("Invalid UTF-8"),
        },
    };
    CString::new(serde_json::to_string(&response).unwrap())
        .unwrap()
        .into_raw()
}
