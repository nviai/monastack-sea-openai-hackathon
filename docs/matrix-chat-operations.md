# Matrix chat operations

Status: built. Date: 2026-10-31. Audience: local workspace operators. Share boundary: repository collaborators. Owner: not assigned.

## 1. Start and inspect

Run from the server checkout. Docker is required for Matrix. Zellij is used when installed. Without it, host services run detached with output in `runtime/logs/`.

```sh
cargo build --locked --manifest-path backend/office-node/Cargo.toml
mkdir -p runtime
cp -n .env.example runtime/.env
MONASTACK_SERVER_HOST=<server-lan-ip> python3 tools/local_office.py start --no-app
python3 tools/local_office.py status
zellij attach monastack-matrix-server
```

- **Start the server with its LAN IP, never 127.0.0.1**: set `MONASTACK_SERVER_HOST=<server-lan-ip>` or `MONASTACK_MATRIX_PUBLIC_URL=http://<server-lan-ip>:8008`. A server started with 127.0.0.1 advertises `homeserver_url` 127.0.0.1:8008, so the apps on other machines cannot reach chat and show "Chat could not connect". Check with `curl -H "Authorization: Bearer <token>" http://<server-lan-ip>:47830/v1/chat/config`. `runtime/server-address.json` remains the default when no host override is supplied. An explicit `MONASTACK_MATRIX_PUBLIC_URL` takes precedence.
- **Preserve the existing runtime**: startup reuses its owned healthy services. It refuses occupied ports. It does not kill unrelated processes or overwrite existing workspace databases.
- **Inspect service output directly**: the `Services` tab contains named foreground command panes. This host has a Zellij 0.45.1 bug where no-focus command tabs remain empty. Named panes preserve the bundled tab bar and status hints without stealing focus. `BE-api` runs authority 47830 and realtime 47831. `BE-member` runs proxy 47840. `Matrix-client` runs the gateway on 8008. `Matrix-synapse` follows the container whose upstream is loopback 8009. `Matrix-postgres` follows the unpublished database container. `LiveKit-server` follows the existing LiveKit container.
- **Run offices without Docker**: use `python3 tools/local_office.py start --no-matrix --no-app`. The authority and member start with chat disabled. LiveKit is skipped when Docker is absent. Stop before changing modes. Status and stop also work without Docker.
- **Start the application optionally**: omit `--no-app` after building the macOS app. Its pane is `FE-macos`. An absent app binary does not prevent the backend-only command from working.
- **Keep client installation small**: client machines need the app and connectivity to the advertised services. They never need Synapse or Postgres containers, admin tokens or JWT secrets. Their member proxies forward chat API requests to the server.

## 2. Stop and restart

Use the stack script to stop its own services.

```sh
python3 tools/local_office.py stop
MONASTACK_SERVER_HOST=<server-lan-ip> python3 tools/local_office.py start --no-app
```

- **Upgrade the existing Matrix layout**: stop before the first upgraded start. Startup preserves Postgres data and moves the signing key and attachments under `runtime/matrix/synapse/`. It recreates only this runtime's stopped containers to adopt the pinned Synapse image and narrow mounts. Never downgrade a migrated Synapse database without a matching backup.
- **Data survives service restarts**: Postgres and attachments remain under `runtime/matrix/`. Stopping containers does not delete that directory. SQLite retains all identity and conversation mappings.
- **Keep failed panes visible**: inspect the named tab before restarting. Startup deliberately replaces an exited command pane when relaunching the same service. It does not resurrect old saved sessions.
- **Standalone Matrix is available**: `python3 tools/matrix_stack.py start|status|stop` manages only Matrix containers and its gateway. It requires the authority at 127.0.0.1:47830 for authenticated client traffic. The full office script is the normal entrypoint.

## 3. Back up and recover

All stores must represent the same workspace when restored.

```sh
MONASTACK_DB=runtime/db/server-office.sqlite3 backend/office-node/target/debug/monastack-office-node backup runtime/backups/manual-before-change.sqlite3
```

- **Keep the automatic migration snapshot**: the first Matrix start backs up an existing authority database into `runtime/backups/`. This uses SQLite's online backup API with integrity checks and mode 0600.
- **Back up chat state separately**: stop the stack before copying `runtime/matrix/`. Preserve its Postgres directory and signing key together with media and bridge secrets. Preserve the authority SQLite database from the same stopped state.
- **Restore as one workspace**: use the existing node `restore` command into a new SQLite path and restore the matching Matrix directory. Avoid restoring a historic permission database against newer chat data without reviewing revoked access.
- **Preserve secrets during repair**: never delete `bridge.json` to rotate a secret casually. The JWT secret in Synapse configuration and the node bridge must agree. Replacing a service token requires updating the private bridge file.
- **Let reconciliation repair interruptions**: after a node crash, restart it against the same directory. Pending user provisioning and room aliases are retried. Epoch drift reconciles room membership. The gateway returns unavailable while its policy authority is offline.
- **Read earlier messages explicitly**: use `GET /v1/chat/legacy/room%3Alobby?limit=50` with the office bearer token. `before` is an exclusive creation timestamp. The server has no legacy write endpoint.

## 4. Verify

These commands use synthetic messages and never activate a microphone or camera.

```sh
cargo test --locked --manifest-path core/Cargo.toml
cargo test --locked --manifest-path backend/office-node/Cargo.toml
cargo build --locked --manifest-path backend/office-node/Cargo.toml
python3 backend/office-node/tests/matrix_gateway_test.py
python3 backend/office-node/tests/matrix_http.py
python3 backend/office-node/tests/http_smoke.py
```

- **Reserve test ports first**: the real Matrix test refuses occupied 47830, 47840, 8008 and 8009. Stop only your own local stack before running it. It uses 127.0.0.1 for all server requests except a self-LAN-address admin denial check.
- **Inspect test evidence locally**: disposable service data and log captures live under `runtime/matrix-http-*`. Zellij session `monastack-matrix-http` retains the named service panes. The test stops its own processes in cleanup.
- **Understand attachment revocation limits**: a user with a valid Matrix token and an already known `mxc` URI can download that file after room revocation. Client ingress prevents revoked room history and search. Media is not room-scoped. See [ADR 0010](adr/0010-matrix-chat.md).
