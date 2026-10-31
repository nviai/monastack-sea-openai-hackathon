# ADR 0004: Isometric office, map v2 and occlusion

Status: accepted.

## Context

Map v1 was an 18×18 grid of nine 5×5 rooms with one-cell gaps, one door cell per room, and one desk anchor per room. The renderer drew every tile, wall bump, prop and avatar with fresh paths on every frame in a single diagonal loop, without real wall height or occlusion. Rooms read as disconnected islands and the acceptance criterion for a polished 2.5D office with corridors, doorways, signage and depth sorting was not met.

## Decision

### Map v2 (`data/seed/nviai/map.v2.json`)

- 30×27 cells. A central lobby (NVIAI sign, products screen, Mona's reception desk) is surrounded by Dev & QA, Product/PM, Meeting, Sales, Customer Support, HR, Lounge and Finance. Two-cell corridors separate every room.
- Rooms have `doors` (a list; doors are two cells wide; the lobby has four doorways). A door must lie on the perimeter and not on a corner.
- Props carry `mount: floor | wall`. Wall props (signs, screens, whiteboards, boards, shelves, art) must sit on wall cells and never collide. Floor props may not overlap a wall; solid floor props may not overlap each other.
- `desks` are seat assignments: a seat cell beside a solid desk prop inside the room, with an optional `assignee`. Assignees are unique and must exist in the seed (checked when the Rust core loads both documents). Assignments mirror the seeded roles as a demonstration, not an organizational statement; HR has one unassigned desk and no invented person.
- `style` per room (floor colour, pattern, accent) and `tile` metrics are rendering hints that the Rust validator ignores.
- Validation (`core/src/map.rs`) checks version 2, room overlap, doors, zones, prop geometry, desks, and that every door, room spawn and seat is reachable from the global spawn.
- **Corridors belong to no room.** Presence in a corridor is reported and authorized as the lobby, the shared commons; the node already treated non-room cells this way. Walking past a restricted room grants nothing.

v1 is no longer accepted. Presence positions are transient (30 s expiry), so no stored data needed migration.

### Renderer (`app/lib/features/office/world/`)

- `office_map.dart`: typed presentation model of the map document. It contains no walkability or policy; room lookup for presence uses `OfficeCore.roomAt` from the Rust core.
- `office_scene.dart`: all static artwork (platform, patterned floors per room, rugs, contact shadows, thin wall slabs with full-height far walls and cut-away near walls, door lintels, furniture, wall decor and signage) is recorded **once** into a `ui.Picture`. Every object with height is also kept as an *occluder* with a depth key (`x + y` of its footprint centre) and screen bounds.
- `world_game.dart`: per frame the game draws the cached picture, then avatars in depth order. After each avatar it repaints only the occluders that are nearer the viewer and overlap that avatar's bounds. This yields correct wall and furniture occlusion without redrawing the scene. A faint ring keeps the local avatar findable behind tall walls. Names, room signs and tooltips are drawn in a constant-size screen overlay.
- Avatars are original programmatic figures. Seeded agents are drawn at their assigned desks as translucent grey figures with an antenna and a grey status dot, labelled "offline agent" on hover; they never move and are never shown as online.
- Rooms the viewer cannot enter (node snapshot when connected, seed preview otherwise) are dimmed and their sign shows a lock. This is a cue only; the node authorizes every request.
- Input: click to walk, click an avatar to open its profile, WASD/arrows along the floor grid (blocked key steps are silent), drag to pan, pinch or scroll to zoom, *Center on me*, *Reset view* (fit the whole office), and a reduced-motion toggle that also honours the system setting. The camera follows the local avatar when it walks near the edge. Hovering highlights the target cell and shows desk assignments.
- `Iso` uses an orthographic 2:1 projection (64×32 tiles). True 3D was not evaluated: there is no camera-rotation or geometry requirement that would justify it.

### Assets and provenance

All artwork is drawn in code with Flutter canvas primitives and the platform font. No image, atlas or third-party asset is used, so there is no DPI/atlas pipeline or licence to track. The look is inspired by warm spatial-office products but copies no asset, layout or branding.

### Shell

The 17-item *Workspace tools* popup overflowed short windows (a macOS integration test could not tap an item off-screen). It is now a grouped, scrollable dialog with the same labels.

## Evidence

- `cargo test --manifest-path core/Cargo.toml`: map v2 validity, doors, wall props, desks, reachability, corridor lookup, private-room path denial, seed/desk cross-check.
- `flutter test`: routing and camera behaviour, reduced motion, click targeting under zoom/pan/reset, and clicking an offline agent opens its profile instead of walking.
- `flutter test integration_test/office_capture_test.dart -d macos`: writes overview and close-up captures (private; they show seeded names).
- `flutter test integration_test/office_measurement_test.dart -d macos`: idle frame timing and memory; see `stage-1-status.md`.
