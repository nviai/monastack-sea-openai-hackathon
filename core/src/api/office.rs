//! Office map and local room policy for the disconnected preview and for
//! client-side route planning. The connected node remains the authority.
use super::{CoreError, CoreErrorKind};
use crate::{allowed, map, Seed};
use std::collections::HashSet;

/// A world cell, not a pixel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cell {
    pub x: i32,
    pub y: i32,
}

impl From<[i32; 2]> for Cell {
    fn from([x, y]: [i32; 2]) -> Self {
        Cell { x, y }
    }
}

/// Validated seed and map, loaded once and owned by Dart until disposed.
#[flutter_rust_bridge::frb(opaque)]
pub struct OfficeCore {
    seed: Seed,
    map: map::Map,
}

impl OfficeCore {
    pub fn load(seed_json: String, map_json: String) -> Result<OfficeCore, CoreError> {
        let seed: Seed = serde_json::from_str(&seed_json)
            .map_err(|e| CoreError::new(CoreErrorKind::InvalidSeed, e.to_string()))?;
        if seed.version != 1 || seed.workspace.id != "nviai" {
            return Err(CoreError::new(
                CoreErrorKind::InvalidSeed,
                "unsupported workspace or version".to_string(),
            ));
        }
        let map: map::Map = serde_json::from_str(&map_json)
            .map_err(|e| CoreError::new(CoreErrorKind::InvalidMap, e.to_string()))?;
        map.validate()
            .map_err(|e| CoreError::new(CoreErrorKind::InvalidMap, e.to_string()))?;
        let rooms: HashSet<&str> = seed.rooms.iter().map(|r| r.id.as_str()).collect();
        if map.rooms.iter().any(|r| !rooms.contains(r.id.as_str())) {
            return Err(CoreError::new(
                CoreErrorKind::InvalidMap,
                "map room missing from seed".to_string(),
            ));
        }
        let actors: HashSet<&str> = seed.actors.iter().map(|a| a.id.as_str()).collect();
        if map
            .desks
            .iter()
            .filter_map(|d| d.assignee.as_deref())
            .any(|a| !actors.contains(a))
        {
            return Err(CoreError::new(
                CoreErrorKind::InvalidMap,
                "desk assignee missing from seed".to_string(),
            ));
        }
        Ok(OfficeCore { seed, map })
    }

    /// Seed policy used only while disconnected; the node decides when connected.
    #[flutter_rust_bridge::frb(sync)]
    pub fn may_enter(&self, actor: String, room: String) -> bool {
        allowed(&self.seed, "nviai", &actor, &room)
    }

    /// Room containing the cell, or `None` for a corridor or outside the map.
    #[flutter_rust_bridge::frb(sync)]
    pub fn room_at(&self, cell: Cell) -> Option<String> {
        self.map.room_at([cell.x, cell.y]).map(|r| r.id.clone())
    }

    /// Shortest walkable route including `start` and `goal`. When
    /// `allowed_rooms` is `None`, the seed policy for `actor` applies.
    pub fn find_path(
        &self,
        actor: String,
        start: Cell,
        goal: Cell,
        allowed_rooms: Option<Vec<String>>,
    ) -> Result<Vec<Cell>, CoreError> {
        let human = self
            .seed
            .actors
            .iter()
            .any(|a| a.id == actor && a.kind == "human");
        let permitted: HashSet<String> = self
            .seed
            .rooms
            .iter()
            .filter(|room| {
                human
                    && allowed_rooms.as_ref().map_or_else(
                        || allowed(&self.seed, "nviai", &actor, &room.id),
                        |rooms| rooms.contains(&room.id),
                    )
            })
            .map(|room| room.id.clone())
            .collect();
        self.map
            .path([start.x, start.y], [goal.x, goal.y], &permitted)
            .map(|path| path.into_iter().map(Cell::from).collect())
            .ok_or_else(|| CoreError::new(CoreErrorKind::Inaccessible, "destination inaccessible"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn core() -> OfficeCore {
        OfficeCore::load(
            include_str!("../../../data/seed/nviai/seed.v1.json").into(),
            include_str!("../../../data/seed/nviai/map.v2.json").into(),
        )
        .unwrap()
    }

    fn spawn(core: &OfficeCore, room: &str) -> Cell {
        core.map
            .rooms
            .iter()
            .find(|r| r.id == room)
            .unwrap()
            .spawn
            .into()
    }

    #[test]
    fn seed_policy_is_default_deny() {
        let c = core();
        assert!(c.may_enter("van".into(), "finance".to_string()));
        assert!(!c.may_enter("an".into(), "finance".to_string()));
        assert!(!c.may_enter("mona".into(), "lobby".to_string()));
    }

    #[test]
    fn paths_respect_seed_and_server_permissions() {
        let c = core();
        let lobby = spawn(&c, "lobby");
        let finance = spawn(&c, "finance");
        assert_eq!(
            c.find_path("an".into(), lobby, finance, None),
            Err(CoreError::new(
                CoreErrorKind::Inaccessible,
                "destination inaccessible"
            ))
        );
        let route = c.find_path("van".into(), lobby, finance, None).unwrap();
        assert_eq!(route.first(), Some(&lobby));
        assert_eq!(route.last(), Some(&finance));
        assert!(route
            .windows(2)
            .all(|w| (w[0].x - w[1].x).abs() + (w[0].y - w[1].y).abs() == 1));
        // A connected snapshot overrides the seed in both directions.
        assert!(c
            .find_path(
                "an".into(),
                lobby,
                finance,
                Some(vec!["lobby".into(), "finance".into()])
            )
            .is_ok());
        assert_eq!(
            c.find_path("van".into(), lobby, finance, Some(vec!["lobby".into()])),
            Err(CoreError::new(
                CoreErrorKind::Inaccessible,
                "destination inaccessible"
            ))
        );
        // Walls and unknown actors are refused even with a granted room list.
        assert!(c
            .find_path("an".into(), lobby, Cell { x: 0, y: 0 }, None)
            .is_err());
        assert!(c
            .find_path(
                "unknown".into(),
                lobby,
                finance,
                Some(vec!["lobby".into(), "finance".into()])
            )
            .is_err());
        // Agents never walk.
        assert_eq!(
            c.find_path("mona".into(), lobby, lobby, None),
            Err(CoreError::new(
                CoreErrorKind::Inaccessible,
                "destination inaccessible"
            ))
        );
    }

    #[test]
    fn desk_assignees_must_exist_in_the_seed() {
        let map = include_str!("../../../data/seed/nviai/map.v2.json")
            .replace("\"assignee\": \"mona\"", "\"assignee\": \"nobody\"");
        assert!(matches!(
            OfficeCore::load(
                include_str!("../../../data/seed/nviai/seed.v1.json").into(),
                map
            ),
            Err(CoreError {
                kind: CoreErrorKind::InvalidMap,
                ..
            })
        ));
    }

    #[test]
    fn room_lookup_and_invalid_documents() {
        let c = core();
        assert_eq!(c.room_at(spawn(&c, "sales")), Some("sales".to_string()));
        assert_eq!(c.room_at(Cell { x: -1, y: -1 }), None);
        assert!(matches!(
            OfficeCore::load("{}".into(), "{}".into()),
            Err(CoreError {
                kind: CoreErrorKind::InvalidSeed,
                ..
            })
        ));
        assert!(matches!(
            OfficeCore::load(
                include_str!("../../../data/seed/nviai/seed.v1.json").into(),
                "{\"version\":1}".into()
            ),
            Err(CoreError {
                kind: CoreErrorKind::InvalidMap,
                ..
            })
        ));
    }
}
