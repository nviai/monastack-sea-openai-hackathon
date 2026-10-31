# ADR 0006: Room voice with a fail-closed LiveKit control plane

Status: accepted for the local topology. Real-microphone and two-device tests are pending (manual).

## Context

The earlier spikes showed self-hosted LiveKit cannot invalidate an issued token: a removed participant rejoined with the same token. The app had no voice.

## Decision

- **Server.** Self-hosted LiveKit `v1.13.10`, pinned by digest, in Docker, listening on 127.0.0.1 only (`backend/media/livekit-dev.sh`). `room.auto_create: false`: a token can only join a media room that the control plane created. No third-party service, STUN or TURN is used.
- **Control plane** (`backend/office-node/src/media.rs`, inside the realtime capability). One `MediaGate` (Rust core) per Monastack room; each gate generation is one media room named `mona-{room}-{epoch}-{generation}`.
  - `POST /v1/media/token {room, session}` requires a current ticket listing the room **and** the caller's live presence session in that room. It then mints a join token: that one media room, microphone audio and (since ADR 0007) camera video only, no data channel, 120 s lifetime. Identity is `actor.session-prefix`.
  - When the access epoch advances, every media room from an older epoch is **deleted before** a new one is created. Deletion disconnects all participants and makes every token for that room useless. If deletion or creation fails, the gate is blocked and no token is issued (HTTP 503).
  - On start-up it deletes all `mona-` rooms left by a previous run before issuing anything, so tokens from before a restart cannot join.
  - Leaving a room (presence moves, leaves or expires) removes that session's participant.
- **App** (`app/lib/features/office/voice/`). Voice is **opt-in per session** ("Join voice in <room>"), resolving open decision 4 for the prototype. The microphone is **off on every join**; unmuting publishes it and triggers the macOS permission prompt (`NSMicrophoneUsageDescription`, `com.apple.security.device.audio-input`). The panel shows muted/live state, who is here, how many you are hearing, and who is speaking; speakers get a ring in the office view. Voice follows the room you walk into, reconnects after a server-side rotation, and reports denial or outage with a pointer to room chat (text fallback).

## Remaining limits

- An actor who is still a member can rejoin a room's voice with an unexpired token after walking out (up to 120 s). This is etiquette, not an authorization breach; membership loss is enforced by room deletion.
- The access epoch is global, so any membership or credential change briefly reconnects every voice room.
- LiveKit can technically see audio (no end-to-end encryption). Media stays on loopback in this topology.
- Not yet verified: audible playback quality, real microphone capture and the macOS permission flow, two physical devices, and network conditions beyond loopback. See `stage-1-status.md` for the manual test procedure.

## Evidence

- `cargo test` (core): `MediaGate` rotation, admission per generation, fail-closed transitions. (node): join/admin token claims and signature.
- `tools/media-spike/.venv/bin/python backend/office-node/tests/voice_control.py` against real LiveKit: member/non-member/not-present/other-session token decisions; lobby and finance audio delivered and isolated; **revoking Finance membership disconnected the connected Finance participants in 0.4 s and the old token could not rejoin**; walking out removed the participant; tokens from before a node restart could not join.
- `tools/media-spike/.venv/bin/python backend/office-node/tests/voice_app.py`: the macOS app joined lobby voice with the microphone off, received a synthetic peer's audio, followed the user into Dev & QA and stopped receiving lobby audio. No microphone was opened.
- `flutter test test/voice_controller_test.dart`: muted joins, room following, 409 retry until presence arrives, denial as text fallback, rejoin after server disconnect, speaking/hearing state.
