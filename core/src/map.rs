//! Grid geometry for the office. Coordinates are world cells, not pixels.
//! Rendering hints in the map document (styles, prop types) are ignored here.
use serde::Deserialize;
use std::collections::{HashMap, HashSet, VecDeque};

pub const MAP_VERSION: u32 = 2;

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
    #[serde(default)]
    pub desks: Vec<Desk>,
}
#[derive(Debug, Deserialize)]
pub struct Zone {
    pub id: String,
    pub room: String,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Mount {
    /// Stands on interior or corridor floor cells.
    #[default]
    Floor,
    /// Decoration on a room's wall cells; never collides.
    Wall,
}
#[derive(Debug, Deserialize)]
pub struct Prop {
    pub id: String,
    pub position: [i32; 2],
    pub footprint: [i32; 2],
    pub collision: bool,
    #[serde(default)]
    pub mount: Mount,
}
impl Prop {
    fn contains(&self, point: [i32; 2]) -> bool {
        let [x, y] = point.map(i64::from);
        let [px, py] = self.position.map(i64::from);
        let [width, height] = self.footprint.map(i64::from);
        x >= px && x < px + width && y >= py && y < py + height
    }
    fn cells(&self) -> impl Iterator<Item = [i32; 2]> + '_ {
        let [x, y] = self.position;
        let [w, h] = self.footprint;
        (x..x + w).flat_map(move |px| (y..y + h).map(move |py| [px, py]))
    }
}
/// A seat assignment. `assignee` is a seed actor ID or an unassigned seat.
#[derive(Debug, Deserialize)]
pub struct Desk {
    pub id: String,
    pub room: String,
    pub prop: String,
    pub seat: [i32; 2],
    pub assignee: Option<String>,
}
#[derive(Debug, Deserialize)]
pub struct Room {
    pub id: String,
    pub bounds: [i32; 4],
    pub doors: Vec<[i32; 2]>,
    pub spawn: [i32; 2],
    pub zone: String,
}
impl Room {
    pub fn contains(&self, p: [i32; 2]) -> bool {
        p[0] >= self.bounds[0]
            && p[0] <= self.bounds[2]
            && p[1] >= self.bounds[1]
            && p[1] <= self.bounds[3]
    }
    fn perimeter(&self, p: [i32; 2]) -> bool {
        self.contains(p)
            && (p[0] == self.bounds[0]
                || p[0] == self.bounds[2]
                || p[1] == self.bounds[1]
                || p[1] == self.bounds[3])
    }
    fn corner(&self, p: [i32; 2]) -> bool {
        (p[0] == self.bounds[0] || p[0] == self.bounds[2])
            && (p[1] == self.bounds[1] || p[1] == self.bounds[3])
    }
    fn wall(&self, p: [i32; 2]) -> bool {
        self.perimeter(p) && !self.doors.contains(&p)
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
        if self.version != MAP_VERSION
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
            if r.doors.is_empty()
                || r.doors.iter().any(|d| !r.perimeter(*d) || r.corner(*d))
                || !r.contains(r.spawn)
                || r.perimeter(r.spawn)
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
            match prop.mount {
                Mount::Wall => {
                    if prop.collision
                        || !prop
                            .cells()
                            .all(|c| self.rooms.iter().any(|room| room.wall(c)))
                    {
                        return Err("wall prop must sit on wall cells");
                    }
                }
                Mount::Floor => {
                    for cell in prop.cells() {
                        if self.rooms.iter().any(|room| room.perimeter(cell)) {
                            return Err(if prop.collision {
                                "solid prop overlaps wall"
                            } else {
                                "floor prop overlaps wall"
                            });
                        }
                        if prop.collision && !solid_cells.insert(cell) {
                            return Err("overlapping solid props");
                        }
                    }
                }
            }
        }
        let mut desk_ids = HashSet::new();
        let mut assignees = HashSet::new();
        for desk in &self.desks {
            let Some(room) = self.rooms.iter().find(|r| r.id == desk.room) else {
                return Err("invalid desk");
            };
            let Some(prop) = self
                .props
                .iter()
                .find(|p| p.id == desk.prop && p.collision && p.mount == Mount::Floor)
            else {
                return Err("invalid desk");
            };
            let beside = prop
                .cells()
                .any(|[px, py]| (px - desk.seat[0]).abs() + (py - desk.seat[1]).abs() == 1);
            if !desk_ids.insert(&desk.id)
                || !room.contains(desk.seat)
                || room.perimeter(desk.seat)
                || !prop.cells().all(|c| room.contains(c))
                || !beside
                || desk
                    .assignee
                    .as_ref()
                    .is_some_and(|a| a.trim().is_empty() || !assignees.insert(a))
            {
                return Err("invalid desk");
            }
        }
        let all = self.rooms.iter().map(|r| r.id.clone()).collect();
        if !self.walkable(self.spawn, &all) {
            return Err("invalid spawn");
        }
        let anchors = self
            .rooms
            .iter()
            .flat_map(|r| r.doors.iter().copied().chain([r.spawn]))
            .chain(self.desks.iter().map(|d| d.seat));
        for p in anchors {
            if self.path(self.spawn, p, &all).is_none() {
                return Err("unreachable anchor");
            }
        }
        Ok(())
    }

    /// Room containing the cell. Corridor cells belong to no room.
    pub fn room_at(&self, p: [i32; 2]) -> Option<&Room> {
        self.rooms.iter().find(|r| r.contains(p))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn map() -> Map {
        serde_json::from_str(include_str!("../../data/seed/nviai/map.v2.json")).unwrap()
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
        assert!(m.path(m.spawn, [9, 9], &allowed).is_some());
        // Corridors belong to no room.
        assert!(m.room_at([9, 9]).is_none());
        assert_eq!(m.room_at(m.spawn).map(|r| r.id.as_str()), Some("lobby"));
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
            position: [14, 11],
            footprint: [1, 1],
            collision: true,
            mount: Mount::Floor,
        });
        assert_eq!(m.validate(), Ok(()));
        let all = m.rooms.iter().map(|room| room.id.clone()).collect();
        assert!(!m.walkable([14, 11], &all));
        let path = m.path([13, 11], [15, 11], &all).unwrap();
        assert!(path.len() > 3);
        assert!(!path.contains(&[14, 11]));
    }
    #[test]
    fn invalid_or_overlapping_solid_geometry_is_rejected() {
        let mut m = map();
        m.props.push(Prop {
            id: "invalid".into(),
            position: [17, 17],
            footprint: [i32::MAX, 1],
            collision: true,
            mount: Mount::Floor,
        });
        assert_eq!(m.validate(), Err("invalid prop geometry"));
        m.props.pop();
        for id in ["one", "two"] {
            m.props.push(Prop {
                id: id.into(),
                position: [8, 3],
                footprint: [1, 1],
                collision: true,
                mount: Mount::Floor,
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
            mount: Mount::Floor,
        });
        assert_eq!(m.validate(), Err("invalid spawn"));
    }
    #[test]
    fn obstacle_cannot_disconnect_room_anchors() {
        let mut m = map();
        m.props.push(Prop {
            id: "blocked-entrance".into(),
            position: [3, 5],
            footprint: [2, 1],
            collision: true,
            mount: Mount::Floor,
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
            mount: Mount::Floor,
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
    #[test]
    fn doors_must_be_on_a_wall_and_not_a_corner() {
        let mut m = map();
        m.rooms[0].doors.push([0, 0]);
        assert_eq!(m.validate(), Err("invalid anchor"));
        m = map();
        m.rooms[0].doors.push([3, 3]);
        assert_eq!(m.validate(), Err("invalid anchor"));
        m = map();
        m.version = 1;
        assert_eq!(m.validate(), Err("invalid map dimensions or version"));
    }
    #[test]
    fn wall_props_cannot_collide_or_leave_the_wall() {
        let mut m = map();
        m.props.push(Prop {
            id: "floating-sign".into(),
            position: [3, 3],
            footprint: [1, 1],
            collision: false,
            mount: Mount::Wall,
        });
        assert_eq!(m.validate(), Err("wall prop must sit on wall cells"));
        m.props.last_mut().unwrap().position = [0, 3];
        assert_eq!(m.validate(), Ok(()));
        m.props.last_mut().unwrap().collision = true;
        assert_eq!(m.validate(), Err("wall prop must sit on wall cells"));
    }
    #[test]
    fn desks_need_an_adjacent_seat_and_unique_assignees() {
        let m = map();
        assert!(m
            .desks
            .iter()
            .any(|d| d.assignee.as_deref() == Some("mona")));
        let mut m = map();
        m.desks[1].seat = [3, 3];
        assert_eq!(m.validate(), Err("invalid desk"));
        let mut m = map();
        m.desks[2].assignee = m.desks[1].assignee.clone();
        assert_eq!(m.validate(), Err("invalid desk"));
        let mut m = map();
        m.desks[1].prop = "dev-whiteboard".into();
        assert_eq!(m.validate(), Err("invalid desk"));
    }
}
