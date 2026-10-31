# Matrix and live-agent integration

Integrated `feat/matrix-slack-chat` at `31a839e` with the local live-agent work preserved at `45ac85c`. The integration branch is `integrate/matrix-live-agents`. No pull-request action or remote push is required for this integration.

## Combined behavior

- Matrix provides the Slack-style workspace dialog, separate office-room conversations, DMs, threads, reactions, files, search and read-only legacy history.
- Collaboration uses the Matrix branch's session/connection split. Its lifecycle also retains office-wide agent appearances, room-scoped captions, audio meters, live-agent controls and configuration tools.
- All six seeded names/personas/voices and CEO/CTO administration remain intact. Appearance polling stays independent of room membership.
- LiveKit is shared by all clients. Only the authority owns the GPT-Live worker and OpenAI credentials. Voice activation stays gated by unmuted speech unless explicitly configured otherwise.
- Schema 24 initializes both Matrix and live-agent tables, retaining all earlier seed migrations. Existing SQLite databases are backed up before the first Matrix-enabled startup.
- Startup manages Synapse, Postgres, the client gateway, shared LiveKit, the authority, the member and the live-agent worker. Matrix can be disabled with `--no-matrix`.
- Combined Flutter dependencies regenerate platform plugin registrations. The macOS CocoaPods framework embedding phase is retained for WebRTC/LiveKit/Rive.

## Review fixes

- Temporary account disablement locks the Synapse account and revokes devices/memberships. Re-enabling unlocks the same identity before profile changes. This avoids Synapse 1.164.1's failing permanent-deactivation reactivation path.
- JWT-only Matrix provisioning does not reset passwords: the homeserver intentionally disables password changes.
- The gateway actually filters directory search responses against current authority policy, excluding disabled users.
- Agent mute/unmute immediately refreshes the controller's hearing state as well as the audio publication.
- The real Synapse test supports hosts without Zellij and records detached service logs. Fixed tuple handling in its two-device sign-out check.
- The LAN launcher honors `--host`, `MONASTACK_SERVER_HOST`, then `runtime/server-address.json`. Its original example address remains only a fallback. Server IP changes require updating the runtime address and restarting services.

## Validation

- Office node: 43 Rust tests; core: 35 Rust tests.
- Live-agent worker: 16 Python tests.
- Gateway/operations: 8 Python tests, including an actual HTTP directory-filter regression.
- Real Synapse + Postgres: 113 integration checks. Evidence: `runtime/logs/matrix-integration-review.log`.
- Flutter: analyzer clean, 212 widget/unit tests, including a session regression for appearance persistence across room changes and room access denial.
- macOS native integration: two authenticated master/member clients share LiveKit, receive one Mona, independently mute/unmute the agent, exchange a real message using the Matrix Dart SDK while voice remains connected, and retrieve all six seeded appearances. Camera and microphone capture stay off. The test temporarily resumes a paused Mona and restores that setting afterward. Evidence: `runtime/logs/matrix-livekit-native-integration.log`.
- HTTP regression suites: seeded accounts, general workflows/backup, legacy history, room administration, shared workspace.
- Normal macOS debug build succeeds after the native integration test.

Native combined verification:

```sh
cd app
MONASTACK_TEST_SHARED_MEDIA=1 MONASTACK_TEST_MATRIX_CHAT=1 MONASTACK_TEST_LIVE_AGENT=1 MONASTACK_CREDENTIAL_STORE=memory flutter test integration_test/shared_media_test.dart -d macos
```

This exercises media readiness and subscriptions without opening a new paid GPT-Live conversation. It does not test actual speech input/output. A second physical LAN machine was not used.

## Data and rollback

The pre-integration authority/member snapshots are in `runtime/backups/before-matrix-20261031-142514/` with private file permissions. Existing passwords, explicit agent settings, role grants and the saved Mona pause state are preserved. The runtime address was corrected to the machine's current private IP during validation; that address is not committed.

Do not run the pre-integration binary against schema 24. Roll back code together with matching SQLite backups. Once chat has real data, back up and restore the matching Matrix/Postgres/media directory too; see [Matrix operations](matrix-chat-operations.md).

Matrix's existing limitations and SDK licensing discussion remain documented in [ADR 0010](adr/0010-matrix-chat.md): encryption is off, attachment revocation has limits, and the Matrix Dart SDK uses AGPL-3.0. This integration does not change those choices.
