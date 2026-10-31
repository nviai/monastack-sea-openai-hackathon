# ADR 0010: Matrix chat owned by the office authority

Status: built, validation recorded in [Lane S validation](../matrix-lane-s-report.md). Date: 2026-10-31. Audience: workspace maintainers. Share boundary: repository collaborators. Owner: not assigned.

## 1. Topology and trust

One server homeserver serves all clients. Member nodes forward the chat contract to the office authority using ADR 0009.

- **Matrix owns text conversations**: Synapse 1.164.1 stores text events in Postgres 17.6. Both Docker references include immutable multi-architecture digests in `tools/matrix_stack.py`.
- **LiveKit retains media calls**: voice and camera keep their existing service and epoch. Matrix uploads are chat attachments and do not replace LiveKit.
- **Clients reach one gateway**: the advertised URL points to port 8008. The gateway accepts only Matrix client and media routes. It refuses admin and federation routes even for a valid admin token.
- **Administration stays on loopback**: Synapse's upstream listener is published as `127.0.0.1:8009`. Postgres has no host port. The gateway never proxies node or Synapse admin routes.
- **Federation stays disabled**: no federation listener is configured. Domain allowlist and trusted key servers are empty. Federation sending and public room access are disabled. The Docker bridge supports host port forwarding. It is not a general egress firewall.
- **Registration stays server owned**: public registration is disabled. A generated shared secret bootstraps a random service administrator. Each container mounts only its own directory. Synapse reads its required service configuration. Neither container can read host-only `bridge.json` or `secrets.json`.
- **Logs remain inspectable locally**: When installed, Zellij command panes own host processes. Without Zellij, detached processes write to `runtime/logs/`. Launch environments use one-use 0600 files and never appear in command arguments. Docker services retain their container workflow and have foreground log-follow tabs. Startup probes verify readiness. On this host Zellij 0.45.1 leaves no-focus command tabs empty, so the visible fallback uses named panes in the existing `Services` tab.

## 2. Identity and token lifecycle

Every human retains the same Matrix identity across names and restarts.

- **Actors map to random localparts**: `matrix_users` stores actor ID as its primary key and the Matrix user ID as a unique value. UUID-based localparts do not use display names or usernames.
- **Provisioning uses backend authority**: the node creates or updates ordinary non-admin Matrix accounts through the loopback admin API. Display names follow the office actor name. Job titles never confer Matrix administration.
- **Login uses a short JWT**: the authenticated node returns HS256 with `sub` equal to the mapped localpart. Issuer is `monastack-node`. Audience is `monastack-matrix`. Expiry is issued time plus 60 seconds. Synapse validates signature, issuer and audience. Its JWT implementation allows 120 seconds of clock skew. The public gateway additionally validates the signature and enforces expiry without that leeway, so the advertised login remains valid for 60 seconds.
- **Agents cannot obtain sessions**: only enabled humans can use session and directory provisioning. Signed Monastack tokens retain the existing session-revocation checks. Operator-enrolled credentials also undergo the human/enabled-account check.
- **Clients own device tokens**: the app exchanges the JWT at Synapse login. Keychain storage and device logout belong to the app lane. Admin credentials and JWT secrets never appear in contract responses.
- **Account revocation uses the epoch**: disabled users lose Matrix devices and memberships during reconciliation. Signed office session revocation or operator-token changes intentionally invalidate every Matrix device for that actor. This includes signing out only one Monastack device. The unchanged session contract does not bind a Matrix device ID to a Monastack session, so the authority cannot safely target only the matching device. This conservative behavior is deliberate for this version: signing out on one device requires Matrix reauthentication on the actor's other devices too. A fresh office login can request another Matrix JWT. The app should still log out its own Matrix device on local sign-out.
- **Secrets persist privately**: generated configuration and credentials live under git-ignored `runtime/matrix/` with file mode 0600. No generated Matrix room or user IDs are source constants.

## 3. Room ownership and recovery

Office permission state remains authoritative. Matrix membership is its projection.

- **Room IDs determine mappings**: `matrix_rooms` maps the stable office room ID to one Matrix room. Human-facing names and topics live in separate metadata. Changing them does not change the mapping or history.
- **Only the node admits members**: both open and restricted rooms use `invite`. Only the service admin can invite or change policy state. Humans retain ordinary message permissions.
- **History visibility is deliberate**: open rooms use `shared`. Restricted rooms and DMs use `joined`, so admission does not disclose earlier restricted history.
- **DMs use canonical sets**: the sorted unique actor list is serialized as the durable DM registry key. Callers are added automatically. One to eight other humans are allowed. Duplicate requests and participant order reuse the same conversation.
- **The service administers DMs**: the service account creates and remains in each room, including DMs. DMs are private from other ordinary workspace users. They are readable by trusted backend operators.
- **Intent precedes external work**: user mappings and reserved random room aliases are committed before Synapse calls. `matrix_intents` records pending operations. Completion is marked only after the external operation succeeds.
- **Crashes reuse reserved aliases**: if Synapse created a room but the node lost its response, reconciliation resolves the reserved alias before attempting creation. This avoids orphan duplicates. A process-wide async gate serializes concurrent provisioning.
- **Transactions stay short**: every SQLite guard is released before an HTTP await. Mapping writes and membership intents use separate committed database operations. No SQLite transaction contains a Synapse call.
- **Reconciliation repairs current state**: startup always reconciles. The existing realtime epoch is checked every 250 milliseconds. Pending failures are retried. The worker recomputes current permissions rather than replaying obsolete grants.
- **Revocation fails closed at ingress**: the client gateway asks a private service-authenticated node policy endpoint for current allowed Matrix rooms. That endpoint calls the existing office permission function and DM registry. It does not maintain another permission model.
- **Long polls recheck permission**: room reads and writes are checked before forwarding and after upstream completion. Search is constrained to current rooms. Sync and notification responses discard unauthorized content. Sync retains the kick/leave membership event.

## 4. Encryption and content limits

The deployment is server readable and trusts the local host.

- **E2EE is disabled deliberately**: rooms do not enable encryption. Device verification and recovery are not implemented by this lane. Server-side search can index plaintext events.
- **History has an ingress gate**: after office revocation the supported client listener denies old history as well as new reads. Synapse alone retains previously admitted history according to Matrix semantics. A trusted local process that bypasses the gateway on 8009 can still retrieve that history with the user's token.
- **Known attachments remain an exception**: Synapse authenticated media validates a user token, not room membership. A revoked room member with a valid token and known `mxc` URI can still download that attachment. This implementation does not claim room-scoped attachment revocation.
- **Legacy media is not public**: authenticated-media mode is explicitly enabled. New uploads cannot be fetched through old unauthenticated download endpoints. URL previews are disabled.
- **Cached content cannot be recalled**: neither the backend nor Matrix can erase text or attachments already saved by a client. The app must clear revoked previews and notifications separately.
- **Local HTTP requires trusted networking**: the development topology uses plaintext HTTP on private LAN or loopback. Internet deployment requires TLS and an appropriate gateway. This lane does not claim production security review.
- **Licensing needs owner review**: Synapse and the planned famedly Flutter Matrix SDK use AGPL-3.0. The repository has no project license. The owner must accept the distribution obligations before shipping the combined product.

## 5. Legacy data transition

Old messages remain identifiable as earlier history.

- **Backups precede first startup**: the stack uses the existing consistent SQLite backup command before starting Matrix for an existing database. Direct Matrix-enabled node startup also guards this transition. A metadata checkpoint prevents repeated migration backups.
- **No messages are impersonated**: old records stay in `messages`. Their IDs and timestamps remain intact. There is no Matrix import and no replay as another sender.
- **History becomes read only**: `/v1/chat/legacy/{scope}` enforces current room or DM authorization and returns newest-first timestamp pages. The old `/v1/messages/{scope}` route, including writes, is removed.
- **Timestamp paging has a limit**: `before` is an exclusive creation timestamp. If more than a page shares one second, clients cannot disambiguate the boundary with this contract alone. This limitation follows the agreed API shape.
- **App queue handling stays separate**: the app lane must surface pending SQLite-chat outbox entries as not sent with copy support. The server never automatically replays those entries into Matrix.

## 6. Sources consulted

The implementation checked current primary documentation on 2026-10-31.

- [Synapse JWT login](https://element-hq.github.io/synapse/latest/jwt.html).
- [Synapse configuration manual](https://element-hq.github.io/synapse/latest/usage/configuration/config_documentation.html), covering listeners and authenticated media.
- [Synapse admin API](https://element-hq.github.io/synapse/latest/usage/administration/admin_api/), including its recommendation to hide admin routes.
- [Synapse user administration](https://element-hq.github.io/synapse/latest/admin_api/user_admin_api.html), covering account creation and device deletion.
- [Synapse room administration](https://element-hq.github.io/synapse/latest/admin_api/rooms.html), covering forced joins and room membership.

## 7. Fix pass 1 operational decisions

Revocation runs before grants and provisioning across the whole workspace.

- **Failures remain isolated and retryable**: a failed member operation does not stop later members. A failed room or user does not stop later rooms or users. Unfinished intents retain their pending state. Retries back off from one second to thirty seconds. A new epoch bypasses the previous epoch's backoff.
- **Reactivation retains the same identity**: provisioning supplies a fresh random password with `logout_devices=false`. Public password login remains disabled. No Monastack password is reused. See [Synapse account management](https://element-hq.github.io/synapse/latest/admin_api/user_admin_api.html#create-or-modify-account).
- **Room listing serves its caller**: `/v1/chat/rooms` ensures only that caller's authorized joins. It does not run a global pass or acquire the global reconciliation lock. Per-resource locks serialize simultaneous room creation and membership changes.
- **Unknown room routes are refused**: the gateway checks every decoded room ID or alias in the path. Only reviewed room endpoint shapes are exposed. The namespaced timestamp endpoint undergoes the same permission check. Revoked leave rooms lose account data and ephemeral events as well as message state.
- **Docker remains optional for offices**: `start --no-matrix --no-app` starts the authority and member without Docker. LiveKit is unavailable when Docker is absent. Matrix-enabled startup requires Docker. Synapse 1.164.1 uses the registry index digest recorded in the stack module. The [official release](https://github.com/element-hq/synapse/releases/tag/v1.164.1) and the live integration test establish the selected version.
- **Room versions keep correct authority**: Synapse 1.164.1 defaults to room version 12, where the creator has implicit power and must be absent from `content.users`. New room creation no longer explicitly inserts the creator. Reconciliation applies node-owned power levels using the room's actual version, including existing rooms from earlier Synapse versions. See [Matrix room version 12](https://spec.matrix.org/v1.16/rooms/v12/).
- **Container migration preserves existing data**: stop this stack before its first upgraded start. Startup moves the signing key and attachments into the Synapse subdirectory. It recreates only stopped containers owned by this runtime when the image or mount changes. Existing Postgres data stays in place. The node alone creates and checkpoints the pre-Matrix SQLite backup.
