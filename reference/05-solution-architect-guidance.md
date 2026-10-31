# Solution Architect guidance

These are architectural lessons and recommendations for Monastack. They are starting points for design and testing, not guarantees about a particular library version or deployment. Validate implementation choices against current documentation and real tests.

## Virtual office and communication

- An isometric 2.5D renderer can provide convincing spatial depth without the complexity of a full 3D pipeline. Cache static floor rendering, draw raised wall faces, sort objects by world depth and define avatar occlusion explicitly. Separate networking, movement simulation and UI state so they can be tested and evolved independently.
- Model positions in world coordinates, reconcile client movement with an authoritative source, and use sequenced presence snapshots or recoverable deltas with heartbeats. For proximity changes, separate enter and exit distances to reduce rapid subscription flapping; select thresholds through user testing.
- Do not rely on a receiving client to voluntarily mute audio that it is not allowed to hear. Enforce media subscription permissions through a trusted mechanism, test with a modified or unauthorized client, and define who controls publication. Separate media rooms can provide an additional boundary. A participant who controls their own audio can still intentionally disclose it; document that limitation.
- Test actual media behavior with the chosen SDK and server versions, including permission changes, reconnect, token expiry and room transitions. Do not present a UI-level mute or a fake media test as proof of privacy.

## Core, sync and runtime

- Separate the Flutter app, reusable Rust domain core, and backend capabilities. Keep sync protocol and merge decisions independent of network I/O where practical; use platform and transport adapters at the boundary.
- Use a reproducible Flutter/Rust bridge build, explicit lifecycle and typed failures. Test calls from Flutter to the actual Rust core on the target platform. Provide snapshot, replay or equivalent recovery for durable state if events can be missed.
- Treat sync, backup, realtime presence, media and long-running agent execution as distinct capabilities. They can be colocated for development without becoming a single security or responsibility boundary.
- A multiuser company workspace needs explicit membership, authorization, retention, conflict and recovery rules. Do not directly transfer assumptions from a personal vault or generic sync library.
- Choose conflict behavior per domain and test concurrent updates, restart, duplicate messages and permission changes. Sensitive actions and external side effects may need an online authority and idempotency rather than automatic merge.

## Agent integration

- Keep agent identity and authorization independent of the coding engine. Select and validate a Codex integration when the Dev Agent stage is implemented; a configured adapter alone does not prove an end-to-end workflow works.
- Distinguish an agent profile from an active runtime. Surface host, execution state, approvals and evidence of completed work; use bounded permissions and durable job ownership for processes that can outlive the app.
