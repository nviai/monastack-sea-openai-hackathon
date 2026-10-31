# Security, sync and execution boundaries

## Nodes

- **App:** Flutter/Flame UI and Rust core on macOS. An agent can run here only while an appropriately authorized host is running.
- **Sync node:** authenticates devices and supports pushing/pulling changes, durable storage, backup, recovery, quotas and retention. It does not run agents or business processes.
- **Process node:** an optional always-on host for the same Rust core, with its own enrolled device/service identity and scoped agent/worker permissions. It may run agents, scheduled jobs and realtime capability; it does not automatically inherit a user's owner privileges.
- **Realtime/media:** transient presence and audio/signaling require a reachable service. Host it separately or as an explicit process-node capability, e.g. a media server. Do not imply a backup-only node provides realtime or voice. Nodes may share a machine while retaining clear responsibility and trust boundaries.

## Data and authorization

Use tenant-scoped identities for human, agent, service and device principals. Enforce authorization on the authority handling room admission, chat, data sync and media, not only in Flutter. Default deny for restricted rooms, scoped delegation, explicit admin override, audit of access changes. A device that already obtained plaintext cannot have that knowledge revoked while offline: document bounded offline permission leases, rejected/pending changes and reconciliation. Keep ephemeral presence separate from persistent sync.

Persist changes transactionally with an outbox; use stable IDs, idempotency, checkpointing, versioned schema/protocol, retry, deduplication, tombstones and restoration. Apply domain-specific conflict rules; do not merge financial transactions using generic last-write-wins. Test duplicate delivery, concurrent updates, restart, restored backup and authorization changes.

The user has not yet chosen end-to-end encryption versus server-readable sync. Document a threat model and explicit prototype choice, and avoid calling it production-ready encryption. A blind sync node cannot enforce content-level ACL by inspecting ciphertext; key distribution and per-scope authorization must prevent unauthorized devices from receiving usable restricted content. If process node reads E2EE data it must be an authorized key-holding participant; define enrollment, rotation, recovery and revocation. Server-readable designs must state who can access plaintext and how it is protected in transit and at rest.

Future agent execution needs assignment, durable job ownership/fencing, least privilege, budgets, approval tied to action content, safe retries, cancellation and audit. Process or app host failure must not silently duplicate an external side effect. Stage 1 can defer full agent execution but must avoid claiming seeded agents are operational.
