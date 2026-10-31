# Stage 1: Virtual office and communication

## Experience

A user opens the macOS app, signs in to the seeded NVIAI workspace, sees a coherent office with colleagues and agents, walks to department rooms, opens a profile or room conversation, and communicates with people. World, room chat and profiles are views over the same identities and permissions. Make the UI inviting and practical for work. Clearly distinguish actual online status from seeded agent profiles.

The aesthetic should approach the welcoming spatial-office experience of flat.social without copying proprietary assets, branding, or layouts. Use an original, warm, low-poly-looking **2.5D isometric** style: orthographic camera, soft shapes and shadows, pastel colors with accessible contrast, distinct floor/wall faces, plants, desks, sofas, doors, meeting tables and readable labels. The current product direction values the illusion of depth, not an unverified promise of true 3D. Start with Flame and evaluate true 3D only if camera rotation or geometry requirements justify a measured spike.

## Rooms and topology

A central lobby with NVIAI signage and Mona's desk leads to Dev & QA, Product/PM, Sales, Customer Support, HR, Finance, Meeting, and Lounge. Design usable corridors, clear doorways and room labels. HR starts empty unless the supplied seed includes an HR member; never invent real personnel. HR and Finance default to restricted membership in the demo. Workspaces can configure room policies.

A department is an organizational grouping. A room has its own access policy, membership and spatial boundary. A zone is a geometry/acoustics concept, and a desk is an assignment. People can belong to multiple departments. Walking past a room does not grant access. Admin overrides must be explicit and auditable. Room entry, room chat and voice subscriptions must agree with policy.

## Implementation requirements

- Versioned map document with tiles, props, anchors, elevation, footprint, collision/walkability, room polygons, doors, acoustic zones, spawn points and desk assignments. Validate overlapping geometry and reachable spawn/door/desk positions.
- Render ground, walls, props, avatars and overlays with consistent depth sorting and occlusion. Define asset DPI, atlas, fallback and license provenance. Original or properly licensed assets only.
- WASD/arrows and click-to-move with pathfinding and collision; camera pan/zoom/focus; hover/selection, avatar profiles, room list and keyboard-accessible alternatives to canvas; reduced-motion option.
- Presence with heartbeat, sequence, reconnect, stale session cleanup and smooth interpolation. Separate transient movement from persistent data. Agent state reflects a real runtime heartbeat; an inactive seed is offline.
- Durable room chat and DM with authorization, sending/error/offline state, idempotent message IDs and reconnect. No unauthorized subscription to restricted rooms.
- Voice via an actual media/signaling capability, e.g. LiveKit if verified; microphone muted by default, macOS permissions, visible speaking/mute state and clear private-room boundaries. Enforce subscription permissions at a trusted boundary, not merely by muting the listener UI. Revoke access when leaving/losing permission and test it. Text fallback when media is unavailable.
- Minimal workspace identity, RBAC and room membership for Stage 1. Validate tenant and actor at every authority boundary. No hardcoded production credentials.

## Acceptance

1. Documented clean macOS build/run and idempotent NVIAI seed; office layout and profiles reflect the seed, without requiring production services or credentials.
2. Two real app instances/devices join the same workspace, see movement and reconnect without ghost avatars; room chat and DM are delivered and survive restart.
3. Authorized and unauthorized users are tested against room entry, chat and media; denied users cannot receive restricted content. Verify revocation and reconnect.
4. Two actual clients exercise voice and mute/privacy when media and microphone permissions are available. If unavailable, report this as unverified and run available automated policy tests; never label a fake as real voice.
5. Run meaningful bridge, geometry, pathfinding, authorization, sync, seed and integration tests. Capture a real screenshot and measure frame time/FPS and memory on a described Mac; 60 FPS is a target, not an unmeasured claim.
6. Provide setup, topology, secrets handling, run/test commands, real versus fake capability status, known gaps and next steps. A local-only mode must state that it cannot supply remote collaboration without the needed services.
