# Room voice agents: operation and verification

Implemented on 2026-10-31. The design is in [live-agent-voice-plan.md](live-agent-voice-plan.md). Matrix chat remains separate.

## Start on this server

From the repository root:

```sh
# First setup; Python 3.14 is the verified runtime.
sh backend/live-agent/setup.sh
cargo build --locked --manifest-path backend/office-node/Cargo.toml
(cd app && flutter pub get && flutter build macos --debug)
# Preserve your existing runtime/.env; add the voice settings from .env.example.
python3 tools/local_office.py start
python3 tools/local_office.py status
```

Only the master needs `OPENAI_API_KEY`. Set `LIVE_AGENTS_ENABLED=1` in `runtime/.env`. The worker uses `OPENAI_LIVE_MODEL=gpt-live-1`, `OPENAI_LIVE_VOICE=marin`, and `OPENAI_MODEL=gpt-4.1-mini` for delegated reasoning. Restart services after configuration changes:

```sh
python3 tools/local_office.py stop
python3 tools/local_office.py start
```

The master API binds `0.0.0.0:47830`, shared realtime binds `:47831`, and shared LiveKit uses `:7880` with RTC TCP `:7881` and UDP `:7882`. The member proxy uses `:47840` and does not run its own agent worker. LAN clients use `./tools/start-client.sh`; this installation advertises `192.168.224.217`.

See [agent configuration and office presentation](agent-configuration.md) for camera defaults, Rive speech effects, bubbles and administrator/Mona configuration tools.

## Using the feature

Sign in, then walk into Lobby, Dev, Product, Sales or Support. The room's selected agent joins LiveKit automatically and follows its configured activation mode: wait for authorized microphone speech (default), or start automatically on media-room entry. Your app automatically joins shared media; the camera defaults on and the microphone remains off. A manual camera-off choice is respected across room changes. Turn on the microphone to speak, including in Vietnamese. Every connected person in that room hears the same agent track. Camera frames are never forwarded to OpenAI by this worker.

Use **Mute agent** to silence only the agent locally. **Leave voice** is respected until you explicitly join again or enter another room. In Dev, select **dev-agent** or **qa-agent**; only the selected agent runs. An organization administrator can pause/resume a room agent. The live panel shows connection state and short captions; the agent avatar gains its live appearance, speaking ring and audio-level-driven Rive mouth from real state. Spoken text appears only above the avatar, not in the right-side live-agent card.

Ask for workspace project/task information or request a new task in an existing public project. Read results are limited to workspace-visible projects. A task request creates a pending proposal for the authenticated speaker. That user must click **Approve task**; the server rechecks room presence and project permissions before creating it. Repeated approvals return the existing result. Rejecting never creates a task. The agent announces the outcome only after a verified result. Other business writes, arbitrary shell commands, external messages and private data read-aloud are outside the implemented tool set.

For overlapping voices, ask again one at a time. Identity comes from authorized microphone track identity and audio timing, never a name spoken into the microphone. Ambiguous commands do not receive a user's permissions.

## Runtime layout

All mutable files remain under `runtime/`:

- `.env`: OpenAI credentials and runtime configuration.
- `live-agent/.venv/`: pinned Python dependencies, installed from `backend/live-agent/requirements.lock`.
- `live-agent/worker.token`: private server-to-worker credential, created with mode `0600`.
- `pids/voice-worker.pid`, `logs/voice-worker.log`: worker process state and operational messages without transcript or audio logging.
- `db/server-office.sqlite3`: room selections/pause flags, usage sessions, pending operations and final task/audit records.

Captions are an in-memory bounded buffer, cleared when the agent lease ends. No raw audio is recorded. Task proposal titles and operation metadata are durable. Audio leaves this host for the configured OpenAI API while a live session is open; app clients receive LiveKit tokens, never the OpenAI project key.

## Limits and recovery

Defaults: four concurrent room workers, a per-agent speech inactivity timeout (default 60 seconds, configurable up to the 600-second safety ceiling) before closing the paid GPT-Live session, a 600-second room lease cap and a 3,600-second daily global budget (UTC day). Local voice activity detection wakes an idle model session; a closed model does not continue listening remotely. Empty rooms release their worker promptly.

Accounting uses reported active GPT-Live duration, with daily deltas allocated to the current UTC day. Waiting in LiveKit with no OpenAI session consumes zero Live duration and does not exhaust the duration cap. Reports are not an OpenAI invoice; usage after an unexpected process crash can lag the last heartbeat. At the session cap, the room pauses and requires an administrator to resume. A reached daily budget prevents new claims and stops current sessions on their next report. These are local limits; provider quotas may reject requests earlier.

A worker reports every two seconds. The master expires a lease after 12 seconds without a valid report, and human presence after 20 seconds. Permission-epoch changes, leaving, pause, agent selection and authority failure revoke/close stale workers. When all microphones are muted, an already running model finishes its current response/work and closes after its configured muted timeout (default five quiet seconds); an enabled but silent mic uses the configured idle timeout. Active sessions are billed until they close, including this quiet grace period. A failed worker retries with a ten-second backoff; status reports an error instead of simulated success. Graceful model finalization is attempted with a bounded wait; unconfirmed finalization is logged and usage is conservatively accounted.

The bridge uses the official OpenAI Python SDK primary Live WebSocket protocol and native LiveKit RTC. This is an explicit bridge, not the older Realtime API or an unverified partner adapter. Audio buffers are bounded; stale queued output is discarded instead of allowing unlimited delay. Speech onset clears local playback queues, while the Live model handles full-duplex conversation.

## Verification

```sh
cargo test --locked --manifest-path backend/office-node/Cargo.toml
runtime/live-agent/.venv/bin/python -m unittest discover -s backend/live-agent -p 'test_*.py'
(cd app && flutter analyze && flutter test test/voice_controller_test.dart test/live_agent_panel_test.dart test/agent_chat_test.dart test/auth_session_test.dart)
```

Explicit paid tests, using synthetic audio and no host capture devices:

```sh
runtime/live-agent/.venv/bin/python backend/live-agent/smoke.py
runtime/live-agent/.venv/bin/python backend/live-agent/check_delegation.py
# Presence/selection/admin test: run sequentially, not alongside other smoke tests.
runtime/live-agent/.venv/bin/python backend/live-agent/check_rooms.py
```

The audio smoke uses two real authenticated LiveKit clients, checks that both receive one Mona participant, plays synthetic TTS through a microphone-source test track and checks shared non-silent output and authenticated input captions. It logs out and removes synthetic presence afterward. The delegated-work check calls the real Responses API against a fake authority, so it verifies tool invocation without creating real business records. Backend database tests separately verify actual transactional approval, rejection, ownership, permission/presence rechecks and idempotency.

The native macOS shared-media integration also verifies that both Flutter clients receive Mona and that local agent mute/unmute preserves the other client and keeps capture off in the explicitly receive-only test configuration. The room-lifecycle check verifies all resident room assignments, Dev/QA selection, admin pause/resume and cleanup when moving to a room without an agent. Run live tests sequentially because signing out advances the global access epoch.

Verified evidence: project key can access `gpt-live-1`; real Live session start/close; two real RTC peers received shared greeting and synthetic-input response; real Responses proposal tool and ambiguity rejection; Rust, Python and Flutter checks; macOS build. Broad acoustic testing on multiple physical machines, measured latency targets and provider outage/load testing remain future validation; synthetic local tests do not prove those conditions.

Official references: [GPT-Live](https://developers.openai.com/api/docs/guides/live), [WebSockets](https://developers.openai.com/api/docs/guides/voice-websockets?voice-api=live), [delegation](https://developers.openai.com/api/docs/guides/live-delegation), [session lifecycle](https://developers.openai.com/api/docs/guides/live-conversations).

Final verification counts: 27 Rust tests, 6 Python routing tests, 19 selected Flutter tests, a successful native two-peer macOS integration, and a successful normal macOS debug build. The final real audio smoke observed 626 non-silent response frames on each peer, authenticated input captions, one Mona participant, and successful real delegated-work verification. These are local synthetic checks, not production load or latency guarantees.
