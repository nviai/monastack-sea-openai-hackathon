# Open decisions

Confirmed: macOS first; office first; distinct sync and optional process node; agent may run on Mac or process node; no old database migration; new NVIAI seed.

Questions to resolve with evidence or product input, without blocking independent Stage 1 implementation:

1. Is sync end-to-end encrypted or server-readable? Who can enroll a process node, access keys, recover backups and revoke devices?
2. Target number of simultaneous office users, minimum Mac hardware and desired frame-rate/memory budget?
3. Can guests enter any rooms? Which HR/Finance/admin overrides and audit policies are required?
4. Is voice always proximity-based or opt-in by room? Is push-to-talk needed? The prototype defaults to muted microphone.
5. Is the later Codex runner allowed to push, create PRs or merge, and which repo/provider and budget are authorized?
6. Which specific offline AI tasks and local Mac model/hardware constraints matter? Do not equate Rust with an implemented edge model.

Prototype assumptions must be visible in an ADR and UI where relevant. They are not authorization to publish, send seeded personal data to outside services, or perform irreversible actions.
