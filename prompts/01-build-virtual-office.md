# Prompt: Build Monastack Stage 1

Open the parent of `prompts/` as your working directory, then give Codex the instructions below.

---

You are the principal product engineer for a new Monastack implementation. Build **Stage 1: a macOS virtual office and communication experience**, with Flutter, Riverpod, a reusable Rust core and clear feature-based boundaries. This is an implementation request: make the product work, not just a proposal or a set of empty directories. Work autonomously through the stage and report concrete results, tests, limitations and blockers.

## Read the project brief

Read `README.md` and every file under `reference/`, especially the virtual-office design, architecture, security boundaries and NVIAI seed. These documents contain the relevant decisions and a sanitized summary of the earlier project. This repository is the destination. Do not assume access to the previous Monastack project or Nodepass; do not require either to build. If existing code or files are present, inspect them and `git status` where applicable, and preserve user changes.

The latest user instructions override this brief. Record material implementation decisions and deviations in `docs/` with rationale and evidence. Make sensible reversible choices where requirements are open; ask only when a decision requires user input, affects irreversible external actions or is essential to safety. Continue unrelated work if blocked. Do not claim anything was tested or works unless verified.

## Product and scope

Monastack is a shared company workspace in which humans and AI agents can eventually work as colleagues. The immediate deliverable is the office: a user opens the Mac app, enters the NVIAI workspace, sees colleagues/agents and departments, moves through the space, and communicates with authorized participants. The office will later connect to task boards, Mona and a Codex-powered Dev Agent. Do not implement fake agent execution or imply that a seeded agent is running; Stage 1 may represent agents as offline profiles.

Implement Stage 1 acceptance from `reference/03-virtual-office.md`: a real office map with Lobby/Mona, Dev & QA, Product/PM, Sales, Customer Support, HR, Finance, Meeting and Lounge; presence, movement, room access, durable chat/DM, media integration, and a reproducible NVIAI seed. Implement the minimal identity, membership, sync and runtime capabilities needed to make this an actual multi-user vertical slice. Future tasks, full agent/MCP infrastructure, HR workflows, CRM, and 100,000 contacts are outside this stage.

## Architecture

Organize `app/`, `core/` and `backend/` according to `reference/02-architecture.md`, adjusting directory/crate boundaries only where justified. Flutter owns the UI, rendering, input and platform APIs; use Riverpod for dependency injection, UI state, lifecycle and async errors. Rust owns reusable domain/use case rules, storage/sync, map and permission rules. Avoid duplicating business policy in Dart. Keep feature internals private and generated bridge code reproducible.

Prototype the Flutter ↔ Rust bridge on macOS early. Evaluate `flutter_rust_bridge` and a compatible build integration; use pinned versions after verification, nonblocking calls, typed errors, clear ownership and event lifecycle. Persistent state must be recoverable after event drops or reconnection. Build actual code and test a real call through the bridge. Do not use Rust as a synonym for edge AI: define future inference boundaries without promising a model has been deployed.

A **sync node** handles storage, sync and backup only. A **process node** is an optional always-on core host for agent/process execution with a distinct enrolled identity; the app can host authorized processes locally while running. Presence and media/signaling need an explicit real-time capability that can be deployed separately or with the process node. Document exactly which components must be running, and offer a clear local development topology. A process node is not required to implement the full future Codex runner during this stage. The user has not chosen E2EE versus server-readable sync; document the trust model and prototype decision with its limitations. Do not claim a blind server enforces plaintext content ACLs. Follow `reference/06-security-and-sync.md`.

## Visual and interaction design

Build an original, polished isometric 2.5D office inspired by the warm spatial-social feel of flat.social, without copying its assets, branding, or layout. Start with Flame; evaluate true 3D only with a concrete need and evidence. Render distinct floor, wall and furniture faces, soft shadows, plants, department signage, avatars with readable names and states, and a cohesive accessible palette. Provide original or properly licensed assets and document provenance.

Map data is versioned and includes room boundaries, doors, zones, props, collision, walkability, spawn points and desk locations. Implement depth sorting/occlusion and pathfinding. Support keyboard movement, click-to-move, pan/zoom, profile and room interactions, plus a usable accessible list-based alternative. Avoid rebuilding all Flutter widgets on every animation frame. Include a screenshot and benchmark measured on the available Mac, reporting hardware and actual frame time/FPS and memory, or state why measurement was not possible.

Treat department, room, zone and desk as distinct concepts. Seed HR and Finance as restricted rooms; do not invent HR employees. Enforce room access in the authority and media path, not only in the UI. Provide real two-client presence and persisted room chat/DM, reconnect and idempotency. Use a real configured media service for voice, with microphone muted by default and visible state; test private-room isolation, and provide text fallback when media is unavailable. Explicitly distinguish real, fake, unavailable and unverified capabilities.

## Seed and security

Use `reference/04-nviai-seed.md` to seed the company, all 11 existing people, and all six agent profiles. Two products are contextual; do not seed unnecessary later-stage business data. Use stable IDs, declarative versioned seed data, reference validation, and idempotent application targeting only the named demo workspace. Never embed old passwords, create production credentials, send seeded people's data to external systems, or publish the workspace. Keep agent presence offline until real runtime evidence exists.

Use tenant-scoped principal identities and default-deny room access. Grant app/process-node devices and agents only the necessary capabilities; implement and test denial at data, room, chat and media boundaries. Clearly define behavior on disconnect and rights revocation. Add transactional outbox, idempotency, schema/versioning and snapshot/recovery appropriate to the scope. A disconnected device cannot have already-read data immediately revoked; represent pending/offline states and constraints honestly.

## Delivery and validation

1. Inspect toolchains, create a concise execution plan, and establish the smallest working Flutter/Rust bridge early. Avoid blocking all work on optional decisions.
2. Deliver usable map, room navigation, identities, presence, chat, media wiring and node profiles in incremental vertical slices. Add Rust/Flutter tests and integration tests that verify behavior rather than merely mirror code.
3. Validate seed twice, unauthorized room denial, policy on reconnect, storage restore, and two actual clients. Test voice with real microphone/media when available; when unavailable, run feasible automated tests and explicitly mark voice unverified. Do not substitute fakes for end-to-end evidence.
4. Provide `docs/` with architecture/ADR, data and sync policy, setup/run/test instructions, configuration, trust boundaries, screenshots, measured performance, capability matrix and known blockers. Do not expose secrets or log private data unnecessarily.
5. Run appropriate formatter, analyzer, Rust tests and Flutter tests; report precise commands/results. Do not delete data, commit, deploy, contact external parties, or perform irreversible external actions unless explicitly asked.

Continue until Stage 1 is complete or an actual external/environment blocker prevents a specific acceptance item. If blocked, complete independent work and report exactly what is unfinished, why, and how to reproduce or resume. Do not mark a stage complete solely because a demo screen exists.
