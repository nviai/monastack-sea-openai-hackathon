pub mod access;
pub mod api;
pub mod documents;
mod frb_generated;
pub mod jobs;
pub mod map;
pub mod media;
pub mod outbox;
pub mod tasks;
// Local prototype domain. This is not a network authorization boundary.
use serde::Deserialize;

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
}
