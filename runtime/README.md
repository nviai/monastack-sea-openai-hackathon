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

Default host root in this workspace: `/Users/phale/hackathon/monastack-sea-openai-hackathon/runtime`.

Office-node runs on the host in the provided setup. LiveKit binds just `runtime/media/livekit.yaml` into its container; the process worker binds only its disposable child directory. Removing Docker containers/volumes leaves these host files intact. Desktop Keychain credentials and the app's sandbox outbox remain managed by macOS; they are not server Docker mounts.
