# Runtime data

All host-side service data belongs under this directory. Only this README is tracked by Git.

```text
runtime/
  .env                  # OpenAI key and node settings (moved here from root .env)
  server-address.json   # LAN address advertised to clients by local_office.py
  db/
    office.sqlite3      # default database, including accounts and sessions
    client-office.sqlite3 # optional separate client/member database
    server-office.sqlite3 # optional separate server database
  media/
    livekit.yaml        # mounted read-only into LiveKit at /livekit.yaml
    media.key           # host-side credentials read by office-node
    server/             # local_office.py: shared LiveKit config/key
    client/             # preserved legacy config, no running client LiveKit
  worker/
    host-token.txt      # optional operator-created worker token
    command.json        # optional operator-created fixed command
    monastack-worker-*/ # temporary child mounted at /work; removed after execution
  logs/                 # local server/client/app process logs
  pids/                 # PIDs managed by tools/local_office.py
  backups/              # operator-created SQLite snapshots
  models/hf/            # optional local model cache
  inference/token.txt   # optional local inference credential
```

The node discovers the repository root from its working directory and uses its `runtime/` even when started from `app/` or `backend/office-node/`. Outside a source checkout, it uses `runtime/` under the working directory. Set `MONASTACK_RUNTIME_DIR` to choose another root, including `/runtime` in a future container deployment. Explicit `MONASTACK_DB`, `MONASTACK_ENV_FILE`, `MONASTACK_DEV_DIR`, and worker `--scratch-root` still override their individual paths.

The node loads `runtime/.env` by default; a root `.env` remains a compatibility fallback. Prepare a new installation with:

```sh
mkdir -p runtime/db runtime/media runtime/worker runtime/backups
# Only if runtime/.env does not already exist:
cp .env.example runtime/.env
```

Existing environment variables take precedence over .env values. Existing databases at the old repository-root paths cause the node to stop with migration instructions rather than silently opening a fresh workspace. Stop the node before moving SQLite files; preserve matching `-wal` and `-shm` sidecars if present, or use the node's consistent `backup` command and restore to the new destination. Explicit old `MONASTACK_DB` values continue to work until you update them.

The default host root is the current checkout’s `runtime/` directory.

Office-node runs on the host in the provided setup. LiveKit binds just `runtime/media/livekit.yaml` into its container; the process worker binds only its disposable child directory. Removing Docker containers/volumes leaves these host files intact. Desktop Keychain credentials and the app's sandbox outbox remain managed by macOS; they are not server Docker mounts.

Room voice agents also use `live-agent/.venv/`, private `live-agent/worker.token`, `pids/voice-worker.pid` and `logs/voice-worker.log`. Session usage, room configuration and confirmed operations live in the server database. See [voice agent operations](../docs/live-agent-voice.md).
## Matrix chat

`python3 tools/local_office.py start --no-app` now includes one Synapse and one Postgres for the server. Both images use immutable digests. The Python client gateway listens on 8008 and the Synapse admin/client upstream is published only on `127.0.0.1:8009`. Postgres has no published port. Member nodes forward `/v1/chat/*` to the authority.

```text
runtime/matrix/
  secrets.json             # generated JWT, registration and database secrets (0600)
  bridge.json              # node-only service token and JWT secret (0600)
  postgres.env             # generated database credentials (0600)
  synapse/                 # only this directory is mounted into Synapse
    homeserver.yaml        # generated Synapse config, JSON-form YAML (0600)
    homeserver.signing.key # homeserver signing key (0600)
    log.config             # console logging config (0600)
    media_store/           # durable Matrix attachments
  postgres/                # only this directory is mounted into Postgres
runtime/backups/
  before-matrix-*.sqlite3   # consistent pre-Matrix SQLite snapshot
```

Live logs remain in Zellij session `monastack-matrix-server`. Attach with `zellij attach monastack-matrix-server`. On this host, these run as named command panes in the `Services` tab: `BE-api`, `BE-member`, `Matrix-postgres`, `Matrix-synapse`, `Matrix-client`, `LiveKit-server` and optionally `FE-macos`. Zellij 0.45.1 creates empty tabs for the no-focus initial-command path, so the launcher uses this visible fallback. Exited command panes remain visible for diagnosis. `stop` targets the managed service PIDs and owned containers and leaves data intact.

See [Matrix chat operations](../docs/matrix-chat-operations.md) for backup, recovery, permissions and tests. No existing messages are imported or posted again. They remain available through the authorized read-only legacy API. Known attachment URLs remain downloadable by a user with a valid Matrix token after room revocation. Treat the node, Synapse, Postgres and their backups as trusted plaintext stores.

Zellij is optional. Without it, host processes run detached and write `runtime/logs/server.log`, `client.log` and `matrix-gateway.log`. Docker containers retain their own `docker logs` output. Launch environments are passed through one-use 0600 files under `runtime/pids/`, consumed before service execution. Use `python3 tools/local_office.py start --no-matrix --no-app` for office services without Matrix. When Docker is absent, LiveKit is also unavailable. Stop before changing between Matrix-enabled and disabled modes.
