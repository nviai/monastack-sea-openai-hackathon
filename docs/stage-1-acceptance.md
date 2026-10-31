# Stage 1 acceptance tracker

Stage 1 is **not complete**. This tracker distinguishes the local development prototype and synthetic media probes from capabilities verified in the application. See `stage-1-status.md` and `media-evaluation.md` for commands, evidence and limitations.

| Acceptance | Evidence available | Still required |
| --- | --- | --- |
| Clean macOS build, seed and usable office | Debug macOS build, idempotent seed, a captured app render, map/path validation, room list, click and keyboard controls | Polish and verify the 2.5D office, full occlusion and accessibility; verify release/universal builds and reproducible setup beyond the tested Mac |
| Two clients, movement, chat and restart | Two macOS app processes have exchanged messages and movement on one loopback node with forced test frames; a separate test verifies queued chat across two distinct app processes | Two physical devices and a secure remote topology; reliable physical input; crash expiry of a second actual app; broader sync/reconnect behavior |
| Room authorization and revocation | Node checks room, chat and presence; a local operator or authenticated local administrator can auditably grant/revoke restricted-room membership; API tests cover competing versions and revocation; an isolated macOS app test explicitly self-granted access, navigated into Finance, then revoked access and returned to the lobby | Authenticated remote administration, hardened identity/device lifecycle, and enforcement through a real media boundary |
| Real voice and privacy | Synthetic LiveKit tests include server/key rotation; a disposable Flutter/macOS SDK client received synthetic silent RTP and a different-room client received no track | A real fail-closed media control plane, actual app integration, microphone permissions and default mute, two actual clients, and adversarial revocation/reconnect tests |
| Tests, screenshot and measurement | Rust and Flutter tests, HTTP and macOS integration, a private local capture and an idle debug frame/memory measurement | Bridge evaluation and reproducible asynchronous bridge, physical devices, media tests, and broader performance/accessibility testing |
| Topology, security and runbooks | Local setup, seed, backups, trust model, known gaps and synthetic probes are documented | Separate and harden sync, presence and media responsibilities; encrypted/managed backup and recovery; operational security review |

The `MediaGate` in Rust models fail-closed issuance transitions but is not wired to a service and cannot revoke a token or stop a server. The Flutter SDK probe is not voice in Monastack. The prototype is loopback-only, and its node can read stored records. None of these checks establishes production readiness or completes Stage 1.
