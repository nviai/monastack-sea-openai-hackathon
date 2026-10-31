# Seeded NVIAI company and accounts

A normal office-node startup now sets up **NVIAI Smart Technology** and creates missing accounts for all 11 seeded human members. Open the app and choose **Sign in** directly. No setup code, invitation or mandatory password change is needed.

Default password for every newly seeded account:

```text
NviaiSeaxOpenAIHackathon
```

| Username | Person | Role |
| --- | --- | --- |
| `an` | Nguyen Van An | Company Administrator |
| `thao` | Do Phuong Thao | Product Manager |
| `hung` | Vu Manh Hung | Software Engineer |
| `tuan` | Tran Anh Tuan | Software Engineer |
| `linh` | Pham Khanh Linh | QA Engineer |
| `mai` | Le Thi Mai | Sales |
| `duc` | Hoang Minh Duc | Customer Support |
| `van` | Ngo Thu Van | Accountant |
| `pha.le` | Pha Le | CEO + Company Administrator |
| `hao.hua` | Hao Hua | CTO + Company Administrator |
| `triet.le` | Triet Le | Company Administrator |

Each password is stored as a separate salted Argon2id hash in `accounts.password_hash`. Agents have no password accounts. Existing company identity, account credentials, usernames and disabled states are preserved. Existing seeded usernames `le-pha`, `hua-hao` (or `hao-hua`) and `le-triet` are migrated to `pha.le`, `hao.hua` and `triet.le` at master startup, preserving passwords and actor IDs.

The one-time `demo-company-accounts-v1` marker prevents account recreation/reset on later restarts. Deleting the SQLite database and starting with a fresh one seeds everything again.

`MONASTACK_SEED_COMPANY=0` opts out of automatic company/account setup. Use it to retain the manual **Set up company** flow or to initialize a fresh node that will join an existing master. Already joined members always skip this seed. Operator CLI commands such as `setup-code`, `enroll` and `join` do not auto-create the demo company.

```sh
# An unconfigured local node intended to join a master:
MONASTACK_SEED_COMPANY=0 backend/office-node/target/debug/monastack-office-node
```

## Database and Docker paths

Office-node currently runs as a host process in the provided run guide. There is no office-node Dockerfile/Compose deployment or account-database Docker mount in the repository.

- Database: `MONASTACK_DB`, default `runtime/db/office.sqlite3` under the repository root. The guide uses `runtime/db/client-office.sqlite3` / `runtime/db/server-office.sqlite3`; shared member requests read/write business records only on the server. This includes passwords, identities and sessions.
- LiveKit container (`backend/media/livekit-dev.sh`): `runtime/media/livekit.yaml` under the repository root on the host → `/livekit.yaml` read-only in the container. `MONASTACK_RUNTIME_DIR` or `MONASTACK_DEV_DIR` can override the source directory.
- LiveKit's `media.key` stays on the host, next to `livekit.yaml`; the office node reads it. Its credentials are also written into the mounted config.
- Optional process worker: a new disposable `runtime/worker/monastack-worker-*` temporary directory on the host → `/work` in its container; no workspace/account database is mounted. `/tmp` and optional `/.codex` are in-memory container filesystems.

Deleting Docker images/containers/volumes does not delete these host files. Removing a bind-mounted container also leaves its source file on the host.

To inspect mounts of a container that exists:

```sh
docker inspect monastack-livekit-dev --format '{{json .Mounts}}'
```

Shared office routing is now the member default: presence and LiveKit are provided by the master. See [ADR 0009](adr/0009-shared-office.md).

The one-time `seed-leadership-admin-v1` migration grants `org-admin` to CEO `pha.le` and CTO `hao.hua`, retaining their `ceo`/`cto` roles. Subsequent restarts preserve explicit permission revocations. All six agents receive persistent [configuration presets](agent-configuration.md).
