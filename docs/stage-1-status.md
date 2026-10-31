# Stage 1 status

Stage 1 is **implemented and verified on one Mac with automated tests**, but it is not signed off. Three checks need hardware or a person and have not been done: real-microphone and real-webcam voice between two people, two physical Macs, and running the x86_64 slice of the universal release build (this Mac has no Rosetta). The manual procedure is at the end of this document. This is a loopback development topology, not a production service. Do not put confidential data in it or expose it to a network.

See [the acceptance tracker](stage-1-acceptance.md) for item-by-item evidence, and the ADRs in [`adr/`](adr/) for design decisions:
- [0001](adr/0001-local-authority.md): authority and records
- [0002](adr/0002-app-feature-layout.md): app layout
- [0003](adr/0003-flutter-rust-bridge.md): Flutter/Rust bridge
- [0004](adr/0004-isometric-office-v2.md): office and map v2
- [0005](adr/0005-realtime-topology.md): authority/realtime split
- [0006](adr/0006-voice-control-plane.md): voice

## Topology

| Component | Required for | Runs as |
| --- | --- | --- |
| macOS app (Flutter/Flame UI + Rust core via `flutter_rust_bridge`) | everything | `flutter run -d macos` |
| Authority / sync node: identity, membership, chat and records, backup | collaboration | `backend/office-node/target/debug/monastack-office-node` on 127.0.0.1:47830 |
| Realtime: presence and voice control plane | presence, voice | embedded in the node by default, or `monastack-office-node realtime` |
| Media server: self-hosted LiveKit 1.13.10 in Docker | voice | `backend/media/livekit-dev.sh start` |
| Process node / agent host | nothing in Stage 1 | optional, see `stages-3-6-status.md` |

Without a node, the app is a **local preview**: the map, room list, people and seed policy work, but there is no presence, chat or voice. Without LiveKit, presence and chat work and the voice panel says voice is unavailable and points to room chat. Without the realtime service, chat works and the panel says presence is unavailable. Remote collaboration needs these services reachable over a secured network, which this topology does not provide.

## Run on macOS

Tested on Apple M6 / 32 GiB, macOS 27.0.1, Flutter 3.47.7 / Dart 3.13.5, Xcode 27.1, Rust 1.95.0, Docker Desktop. From the repository root:

```sh
cargo build --manifest-path core/Cargo.toml
cargo build --manifest-path backend/office-node/Cargo.toml
umask 077
export MONASTACK_DB="$PWD/office.sqlite3"
openssl rand -hex 32 > local-an-token.txt
backend/office-node/target/debug/monastack-office-node enroll an < local-an-token.txt

# Optional voice: starts LiveKit on 127.0.0.1:7880-7882 with random local credentials.
# If the repository is on a volume Docker Desktop does not share (for example under /Volumes),
# first run: export MONASTACK_DEV_DIR="$HOME/.monastack-dev" and use that path for the key file below.
backend/media/livekit-dev.sh start
export MONASTACK_MEDIA_URL=ws://127.0.0.1:7880 MONASTACK_MEDIA_KEY_FILE="$PWD/.monastack-dev/media.key"

export MONASTACK_REALTIME_PORT=47831   # embedded realtime; ephemeral if unset
backend/office-node/target/debug/monastack-office-node
```

In a second terminal: `cd app && flutter run -d macos`. Paste the token from `local-an-token.txt` and connect. Enroll other seeded people with their own random tokens to try a second identity.

To run realtime as a separate process, create a shared key with `openssl rand -hex 32 > .monastack-dev/realtime.key` and set `MONASTACK_REALTIME_KEY_FILE` to it in both terminals. Then start the node with `MONASTACK_REALTIME=external` and the realtime service with `monastack-office-node realtime`. The media variables go on the realtime service.

**Secrets.** Bearer tokens, `.monastack-dev/` (realtime and LiveKit keys) and the database are private local files. They are git-ignored and created with mode 0600 or 0700. The node stores only SHA-256 hashes of bearer tokens. Tokens are passed on stdin, never as arguments. A local operator revokes a credential with `monastack-office-node revoke < token-file`. Room membership is changed with `room grant|revoke ROOM ACTOR`, or in the app by an organization admin. Every such change is audited and advances the realtime epoch, so presence and voice access end immediately. There is no expiry, rate limiting or credential UI, and nothing here is a production credential.

## Office

- **Map v2.** The office is 30×27 cells. A central lobby (NVIAI sign, products screen, Mona's reception) connects through two-cell corridors and wide doorways to Dev & QA, Product/PM, Meeting, Sales, Customer Support, HR, Lounge and Finance.
- **Validation.** Rooms, zones, doors, props (floor and wall-mounted), collision, spawns and desk assignments are validated in Rust, including reachability of every anchor. HR is restricted, with one unassigned desk and no invented person.
- **Rendering.** The 2.5D view is original programmatic art: patterned floors, full-height far walls and cut-away near walls, door lintels, furniture, wall decor, signage and shadows. Static art is cached once. Avatars are depth-sorted and occluded by walls and furniture, with constant-size name labels and room signs.
- **Agents.** Seeded agents sit at their desks as translucent grey "offline agent" figures. No agent runtime exists.
- **Input and camera.** Click to walk with Rust pathfinding, WASD/arrows, drag to pan, pinch or scroll to zoom, center on me, reset view, and camera follow. Hovering shows desk assignments. Clicking an avatar opens its profile. Rooms you cannot enter are dimmed and show a lock. Reduced motion (system or toggle) removes stepped walking and interpolation.
- **Accessibility.** The room list and the people list are keyboard-reachable alternatives to the canvas. Large-text layouts and VoiceOver on the canvas have not been audited.
- **Screenshots.** `flutter test integration_test/office_capture_test.dart -d macos` writes overview and close-up captures to the app container. They show seeded names, so keep them private (`docs/private/` is git-ignored).

## Presence, chat and voice

- **Presence** is ephemeral and held by the realtime service. The app publishes its position within about 120 ms of moving, sends a 5 s heartbeat, and reads presence every second. Remote one-cell moves are interpolated. A session expires 20 s after its last heartbeat. A second macOS app killed with SIGKILL disappeared from the first app's view within the expiry window and did not come back (`app_crash_app.py`).
- **Chat.** Room chat and DMs are authorized and stored by the authority, with idempotent IDs, a durable local send queue, reconnect, scoped history and revocation. This is unchanged from the earlier prototype and described in the tests below.
- **Voice** is opt-in per session. The microphone starts muted on every join, and voice follows the room you are in. Speakers get a ring in the office view. Access is enforced by the media control plane, not by the UI (ADR 0006). If voice fails, the panel points to room chat.
- **Camera faces.** In voice, "Turn camera on" publishes your webcam; it replaces your avatar's face for everyone in the same room's voice, and theirs replace their faces for you. The camera is off on every join, including when voice follows you into another room (ADR 0007). Verified with a synthetic camera peer against real LiveKit; a real webcam and the macOS camera prompt are not verified.

## Trust model and limits

- **Server-readable prototype.** The node and anyone with filesystem access can read the SQLite database. LiveKit can read audio. Traffic is plaintext HTTP/WebSocket on loopback. There is no end-to-end encryption, no offline permission lease, and no managed or encrypted backup.
- **No forgetting.** A device cannot be made to forget data it already received.
- **Revocation.** It reaches presence immediately in the embedded mode and in about 1 s in separate mode. For voice it ends the connection within about 0.4 s. Any access change briefly reconnects all voice rooms and hides presence until each client republishes.
- **Spatial rejoin.** A member who walks out of a room can still rejoin that room's voice with an unexpired token, for up to 120 s.
- **Camera.** LiveKit can read video as well as audio. Faces are drawn above the office canvas, so walls fade them rather than hide them.
- **Other platforms.** iOS, Android, web, Windows and Linux are scaffolds with icons only; they have not been built or run, and the Rust core is bundled for macOS only.
- **Not production.** Identity is a locally provisioned bearer token, with no device lifecycle. Remote administration, TLS and a security review are not done.

## Measurement

On the tested Mac, `flutter test integration_test/office_measurement_test.dart -d macos` ran a debug build in fully live frame mode for 5 s. Results:

| Scenario | Frames / 5 s | FPS | p95 build | p95 raster | RSS |
| --- | --- | --- | --- | --- | --- |
| Idle overview | 301 | 60.2 | 0.84 ms | 1.58 ms | 404 MB |
| Walking lobby → Dev & QA, zoomed, camera following | 300 | 59.8 | 1.27 ms | 1.42 ms | 406 MB |

 This was one run under the test harness, which could not bring the window to the foreground. It does not establish profile-mode performance or performance with many clients.

## Tests

From the repository root:

```sh
cargo test --manifest-path core/Cargo.toml
cargo test --manifest-path backend/office-node/Cargo.toml
python3 backend/office-node/tests/http_smoke.py
python3 backend/office-node/tests/multi_node_finance.py
python3 backend/office-node/tests/realtime_separate.py
python3 tools/test_bundle_assets.py
(cd app && MONASTACK_CORE="$(cd ../core && pwd)/target/debug/libmonastack_core.dylib" flutter test && flutter analyze)
(cd app && flutter test integration_test/office_test.dart -d macos)
python3 backend/office-node/tests/app_integration.py        # app ↔ node, outbox, leave
python3 backend/office-node/tests/room_membership_app.py    # grant, walk in, revoke, return to lobby
python3 backend/office-node/tests/chat_history_app.py
python3 backend/office-node/tests/presence_crash_app.py     # synthetic peer killed
python3 backend/office-node/tests/chat_process_restart.py
python3 backend/office-node/tests/two_app_integration.py    # two macOS apps, chat/DM, presence, node restart
python3 backend/office-node/tests/app_crash_app.py          # second macOS app killed with SIGKILL
tools/media-spike/.venv/bin/python backend/office-node/tests/voice_control.py  # LiveKit, adversarial
tools/media-spike/.venv/bin/python backend/office-node/tests/voice_app.py      # macOS app voice
```

The macOS tests drive Flutter controls directly and force frames, because the runner cannot bring the windows to the foreground. They do not exercise physical mouse or keyboard input. The voice tests use Docker, generated silence and random credentials, and never open a microphone. Results from the latest run are in the acceptance tracker.

## Manual verification still required

1. **Two people, real microphones.** Start LiveKit and the node as above. Enroll `an` and `van`. Run one app normally. For the second app, copy `app/` and give the copy a different `PRODUCT_BUNDLE_IDENTIFIER` (as `two_app_integration.py` does), or use a second Mac with access to this Mac's loopback over an SSH tunnel.
   - Both people join voice in the Lobby. Check that the microphone shows **Muted** and that the macOS permission prompt appears only on the first unmute.
   - Speak, and check that the speaking ring and the "hearing" count update.
   - Walk one person into Dev & QA and check that they stop hearing each other.
   - Have `van` enter Finance, then run `room revoke finance van`. Check that `van` is disconnected and cannot rejoin Finance voice.
   - Both turn the camera on. Check that the macOS camera prompt appears on first use, that each webcam replaces that person's face for the other, that the camera is off again after walking into another room, and that a person outside the room never sees it.
2. **Two physical Macs.** The services listen on loopback only by design. Use an SSH port forward for 47830, the realtime port and 7880–7882, or wait for a secured remote topology.
3. **Release build on Intel.** `flutter build macos --release` produced a signed universal app: the app binary and `libmonastack_core.dylib` are both x86_64 + arm64, built by `bundle_core.sh` in Release. The arm64 release app launched and ran without core-load errors. The x86_64 slice has not been run, because this Mac has no Rosetta. Notarization and distribution are out of scope.

## Manual local backup and restore

With the node binary built and `MONASTACK_DB` set to the source database, `backend/office-node/target/debug/monastack-office-node backup /path/to/new-snapshot.sqlite3` takes a SQLite-consistent snapshot, including while the node is running. It refuses an existing destination or SQLite sidecar and checks database integrity. To restore into a **new, nonexistent** database path, run `MONASTACK_DB=/path/to/new-restored.sqlite3 backend/office-node/target/debug/monastack-office-node restore /path/to/new-snapshot.sqlite3`; start a node using that new database only after verifying it. Existing databases are never replaced. An error after file creation can leave an incomplete new destination; inspect or remove only that newly created file before retrying. The snapshot includes plaintext private records and token hashes; protect it as private data. It is neither encrypted nor automated. The test checks a live backup, refusal to overwrite, restoration, the node identity, data and authorization after restart.
