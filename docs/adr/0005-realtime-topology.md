# ADR 0005: Separate authority and realtime capabilities

Status: accepted for the local topology.

## Context

One loopback process stored records, authenticated users, enforced room policy, and kept presence in the same SQLite database. The brief requires sync/authority, presence and media to be separable capabilities with explicit trust boundaries, and ephemeral presence kept apart from persistent data.

## Decision

| Capability | Process | State | Trusts |
| --- | --- | --- | --- |
| **Authority / sync** (`monastack-office-node`) | loopback `MONASTACK_NODE_PORT` (47830) | SQLite: identities, credentials (hashes), rooms, membership, chat, records, audit, backup | bearer credentials it enrolled |
| **Realtime** (presence + media control) | embedded (default) or `monastack-office-node realtime` | memory only: presence sessions, media gates | tickets signed by the authority; the authority's access epoch |
| **Media** | self-hosted LiveKit in Docker (`backend/media/livekit-dev.sh`) | rooms and participants | join tokens minted by the realtime control plane |

- **Tickets.** `POST /v1/realtime/ticket` (bearer-authenticated) returns an HMAC-SHA256-signed ticket: actor, the rooms the actor may enter now, the access epoch, and a 30 s expiry, plus the realtime URL (loopback only; the client rejects anything else). The realtime service never sees the bearer credential and has no database access.
- **Epoch.** The authority increments a `realtime_epoch` counter in the same transaction as every room-membership change (app or operator) and credential revocation. The realtime service rejects tickets from older epochs and hides presence written under them, so revocation does not wait for ticket expiry. Embedded realtime reads the epoch from the authority database; a separate realtime process polls `GET /v1/realtime/epoch` every second and **fails closed** (HTTP 503) when it has not confirmed the epoch for 10 s.
- **Presence** is now in memory, expires 20 s after the last heartbeat, and is validated against the shared Rust map (walkable cell, room matches cell, room listed in the ticket). Corridors report as the lobby. Reads only return sessions in rooms listed in the reader's ticket. A restart clears presence, which is correct for transient state. The legacy `presence` table is left in the schema but no longer written.
- **Client.** The app requests a ticket, refreshes it at half-life or after a 401, publishes its position immediately after movement (debounced 120 ms) and as a 5 s heartbeat, and reads presence every second. Presence failures do not affect chat; the panel says "Presence unavailable · text chat still works".
- **Deployment modes.** `MONASTACK_REALTIME=embedded` (default) starts realtime in the authority process on `MONASTACK_REALTIME_PORT` (ephemeral when unset) with a fresh key or `MONASTACK_REALTIME_KEY_FILE`. `external` advertises a separately started `office-node realtime` sharing `MONASTACK_REALTIME_KEY_FILE` (32 random bytes, hex). `off` disables it. Both modes run the same code; only the epoch source differs.

## Consequences

- Revocation latency for presence: immediate when embedded; ≤ ~1 s observed when separate (`realtime_separate.py`).
- Any membership or credential change hides all presence until each client re-publishes (≤ 1 s with the new client loop). This trades a brief flicker for a simple, global revocation rule.
- The shared HMAC key is the trust anchor between the two services. It is a local file in this topology; a remote deployment needs TLS, key rotation and a real service identity.
- Presence races between two authority processes on one database (previously in `multi_node_finance.py`) no longer exist; the test now checks duplicate heartbeats against one realtime service.

## Evidence

- `cargo test --manifest-path backend/office-node/Cargo.toml`: ticket signing/forgery/expiry, key format, stale-epoch fail-closed, presence validation, private-room filtering, corridor reporting, revocation by epoch.
- `python3 backend/office-node/tests/http_smoke.py`: presence over tickets, forged and bearer-as-ticket rejection, credential revocation hiding presence and invalidating an unexpired ticket.
- `python3 backend/office-node/tests/realtime_separate.py`: two processes; revocation observed in 0.8 s, fail-closed 10.7 s after the authority stopped, recovery after restart.
- macOS app tests (`app_integration.py`, `room_membership_app.py`, `two_app_integration.py`, `app_crash_app.py`) run against the embedded realtime service.
