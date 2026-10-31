//! Grid geometry for the prototype office. Coordinates are world cells, not pixels.
use serde::Deserialize;
use std::collections::{HashMap, HashSet, VecDeque};
#[derive(Debug, Deserialize)]
pub struct Map {
    pub version: u32,
    pub width: i32,
    pub height: i32,
    pub rooms: Vec<Room>,
    pub spawn: [i32; 2],
    #[serde(default)]
    pub zones: Vec<Zone>,
    #[serde(default)]
    pub props: Vec<Prop>,
}
#[derive(Debug, Deserialize)]
pub struct Zone {
    pub id: String,
    pub room: String,
}
#[derive(Debug, Deserialize)]
pub struct Prop {
    pub id: String,
    pub position: [i32; 2],
    pub footprint: [i32; 2],
    pub collision: bool,
}
impl Prop {
    fn contains(&self, point: [i32; 2]) -> bool {
        let [x, y] = point.map(i64::from);
        let [px, py] = self.position.map(i64::from);
        let [width, height] = self.footprint.map(i64::from);
        x >= px && x < px + width && y >= py && y < py + height
    }
}
#[derive(Debug, Deserialize)]
pub struct Room {
    pub id: String,
    pub bounds: [i32; 4],
    pub door: [i32; 2],
    pub spawn: [i32; 2],
    pub desk: [i32; 2],
    pub zone: String,
}
impl Room {
    pub fn contains(&self, p: [i32; 2]) -> bool {
        p[0] >= self.bounds[0]
            && p[0] <= self.bounds[2]
            && p[1] >= self.bounds[1]
            && p[1] <= self.bounds[3]
    }
    fn wall(&self, p: [i32; 2]) -> bool {
        self.contains(p)
            && (p[0] == self.bounds[0]
                || p[0] == self.bounds[2]
                || p[1] == self.bounds[1]
                || p[1] == self.bounds[3])
            && p != self.door
    }
}
impl Map {
    pub fn walkable(&self, p: [i32; 2], allowed: &HashSet<String>) -> bool {
        if p[0] < 0 || p[1] < 0 || p[0] >= self.width || p[1] >= self.height {
            return false;
        }
        if self
            .props
            .iter()
            .any(|prop| prop.collision && prop.contains(p))
        {
            return false;
        }
        for r in &self.rooms {
            if r.contains(p) && (r.wall(p) || !allowed.contains(&r.id)) {
                return false;
            }
        }
        true
    }
    pub fn path(
        &self,
        start: [i32; 2],
        goal: [i32; 2],
        allowed: &HashSet<String>,
    ) -> Option<Vec<[i32; 2]>> {
        if !self.walkable(start, allowed) || !self.walkable(goal, allowed) {
            return None;
        }
        let mut queue = VecDeque::from([start]);
        let mut prev = HashMap::from([(start, start)]);
        while let Some(p) = queue.pop_front() {
            if p == goal {
                let mut path = vec![p];
                let mut c = p;
                while c != start {
                    c = prev[&c];
                    path.push(c);
                }
                path.reverse();
                return Some(path);
            }
            for next in [
                [p[0] + 1, p[1]],
                [p[0] - 1, p[1]],
                [p[0], p[1] + 1],
                [p[0], p[1] - 1],
            ] {
                if self.walkable(next, allowed) && !prev.contains_key(&next) {
                    prev.insert(next, p);
                    queue.push_back(next);
                }
            }
        }
        None
    }
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.version != 1
            || self.width <= 0
            || self.height <= 0
            || self.width > 256
            || self.height > 256
        {
            return Err("invalid map dimensions or version");
        }
        let mut cells = HashSet::new();
        let mut ids = HashSet::new();
        for r in &self.rooms {
            if !ids.insert(&r.id)
                || r.bounds[0] < 0
                || r.bounds[1] < 0
                || r.bounds[2] >= self.width
                || r.bounds[3] >= self.height
                || r.bounds[2] - r.bounds[0] < 2
                || r.bounds[3] - r.bounds[1] < 2
            {
                return Err("invalid room");
            }
            for x in r.bounds[0]..=r.bounds[2] {
                for y in r.bounds[1]..=r.bounds[3] {
                    if !cells.insert([x, y]) {
                        return Err("overlapping rooms");
                    }
                }
            }
            if !r.contains(r.door)
                || !r.contains(r.spawn)
                || !r.contains(r.desk)
                || r.wall(r.spawn)
                || r.wall(r.desk)
                || !(r.door[0] == r.bounds[0]
                    || r.door[0] == r.bounds[2]
                    || r.door[1] == r.bounds[1]
                    || r.door[1] == r.bounds[3])
            {
                return Err("invalid anchor");
            }
        }
        let mut zone_ids = HashSet::new();
        for zone in &self.zones {
            if zone.id.trim().is_empty()
                || !zone_ids.insert(&zone.id)
                || !self.rooms.iter().any(|room| room.id == zone.room)
            {
                return Err("invalid zone reference");
            }
        }
        for room in &self.rooms {
            if !self
                .zones
                .iter()
                .any(|zone| zone.id == room.zone && zone.room == room.id)
            {
                return Err("invalid room zone");
            }
        }
        let mut prop_ids = HashSet::new();
        let mut solid_cells = HashSet::new();
        for prop in &self.props {
            let [x, y] = prop.position;
            let [width, height] = prop.footprint;
            if prop.id.trim().is_empty()
                || !prop_ids.insert(&prop.id)
                || x < 0
                || y < 0
                || width <= 0
                || height <= 0
                || i64::from(x) + i64::from(width) > i64::from(self.width)
                || i64::from(y) + i64::from(height) > i64::from(self.height)
            {
                return Err("invalid prop geometry");
            }
            if prop.collision {
                for px in x..x + width {
                    for py in y..y + height {
                        if !solid_cells.insert([px, py]) {
                            return Err("overlapping solid props");
                        }
                        if self.rooms.iter().any(|room| room.wall([px, py])) {
                            return Err("solid prop overlaps wall");
                        }
                    }
                }
            }
        }
        let all = self.rooms.iter().map(|r| r.id.clone()).collect();
        if !self.walkable(self.spawn, &all) {
            return Err("invalid spawn");
        }
        for r in &self.rooms {
            for p in [r.door, r.spawn, r.desk] {
                if self.path(self.spawn, p, &all).is_none() {
                    return Err("unreachable anchor");
                }
            }
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn map() -> Map {
        serde_json::from_str(include_str!("../../data/seed/nviai/map.v1.json")).unwrap()
    }
    #[test]
    fn seed_map_is_valid_and_paths_reach_all_anchors() {
        assert_eq!(map().validate(), Ok(()));
    }
    #[test]
    fn private_room_cannot_be_entered() {
        let m = map();
        let allowed = m
            .rooms
            .iter()
            .filter(|r| r.id != "finance" && r.id != "hr")
            .map(|r| r.id.clone())
            .collect();
        let finance = m.rooms.iter().find(|r| r.id == "finance").unwrap();
        assert!(m.path(m.spawn, finance.spawn, &allowed).is_none());
        assert!(m.path(m.spawn, [17, 17], &allowed).is_some());
    }
    #[test]
    fn overlap_is_rejected() {
        let mut m = map();
        m.rooms[1].bounds = m.rooms[0].bounds;
        assert_eq!(m.validate(), Err("overlapping rooms"));
    }
    #[test]
    fn solid_prop_blocks_cells_and_paths_route_around_it() {
        let mut m = map();
        m.props.push(Prop {
            id: "synthetic-obstacle".into(),
            position: [2, 1],
            footprint: [1, 1],
            collision: true,
        });
        assert_eq!(m.validate(), Ok(()));
        let all = m.rooms.iter().map(|room| room.id.clone()).collect();
        assert!(!m.walkable([2, 1], &all));
        let path = m.path([1, 1], [3, 1], &all).unwrap();
        assert!(path.len() > 3);
        assert!(!path.contains(&[2, 1]));
    }
    #[test]
    fn invalid_or_overlapping_solid_geometry_is_rejected() {
        let mut m = map();
        m.props.push(Prop {
            id: "invalid".into(),
            position: [17, 17],
            footprint: [i32::MAX, 1],
            collision: true,
        });
        assert_eq!(m.validate(), Err("invalid prop geometry"));
        m.props.pop();
        for id in ["one", "two"] {
            m.props.push(Prop {
                id: id.into(),
                position: [5, 5],
                footprint: [1, 1],
                collision: true,
            });
        }
        assert_eq!(m.validate(), Err("overlapping solid props"));
    }
    #[test]
    fn colliding_spawn_is_not_a_valid_map() {
        let mut m = map();
        m.props.push(Prop {
            id: "blocked-spawn".into(),
            position: m.spawn,
            footprint: [1, 1],
            collision: true,
        });
        assert_eq!(m.validate(), Err("invalid spawn"));
    }
    #[test]
    fn obstacle_cannot_disconnect_room_anchors() {
        let mut m = map();
        m.props.push(Prop {
            id: "blocked-crossing".into(),
            position: [5, 5],
            footprint: [1, 1],
            collision: true,
        });
        assert_eq!(m.validate(), Err("unreachable anchor"));
    }
    #[test]
    fn solid_prop_cannot_overlap_room_wall() {
        let mut m = map();
        m.props.push(Prop {
            id: "wall-obstacle".into(),
            position: [0, 0],
            footprint: [1, 1],
            collision: true,
        });
        assert_eq!(m.validate(), Err("solid prop overlaps wall"));
    }
    #[test]
    fn zones_must_be_unique_and_reference_their_room() {
        let mut m = map();
        m.zones[0].room = "missing".into();
        assert_eq!(m.validate(), Err("invalid zone reference"));
        m = map();
        m.rooms[0].zone = "missing".into();
        assert_eq!(m.validate(), Err("invalid room zone"));
        m = map();
        m.zones[1].id = m.zones[0].id.clone();
        assert_eq!(m.validate(), Err("invalid zone reference"));
    }
}
