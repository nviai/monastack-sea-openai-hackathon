# ADR 0008: Workspace identity, sign-in and identity federation

Status: accepted for the local topology. Not reviewed for production; see limits.

## Context

Until now a person joined by pasting a bearer token that a local operator created with `office-node enroll`. There was no company setup, no password, no sign-out, no device list and no way for a second node to share accounts. The user asked for a complete but simple, self-made identity (no Authentik): a node holds the accounts, and either a server node or the first local node set up becomes the master that other nodes take sign-in from.

## Decision

**Master and members.** The node on which the company is set up becomes the workspace's identity **master**. It alone stores password hashes, sessions with their refresh tokens, invitations and the Ed25519 signing key (in its SQLite metadata, protected like the rest of the database). Other nodes join as **members** with a one-hour, single-use join code created by an organization admin (`office-node join http://127.0.0.1:PORT`, code on stdin). A member pulls a directory from the master every 5 s: the public key, the workspace name, people, account usernames and disabled flags, and the sessions revoked recently enough that their access tokens may still be valid. It never receives password hashes or refresh tokens. Sign-in, refresh, sign-out, invitations, passwords, device lists and admin requests sent to a member are forwarded to the master. Only identity is federated: chat, tasks and other records stay on the node that stores them.

**Company setup.** An unconfigured node prints a setup code (`XXXX-XXXX-XXXX-XXXX`, 80 bits) on start; `office-node setup-code` prints a fresh one. In the app, "Set up company" takes the code, the company name, who you are (a seeded person or someone new), a username and a password. Five wrong codes block setup until a new code is generated. Setup happens once; the person becomes an organization admin.

**Credentials.**
- Passwords: at least 10 characters, Argon2id (default parameters), verified off the async runtime. Unknown usernames are checked against a dummy hash so timing does not reveal accounts. Five failures lock the account for 30 s, doubling to at most 15 min; failures are audited.
- Access tokens: `v1.<claims>.<signature>`, Ed25519 over `{workspace, actor, session, iat, exp}`, valid 10 minutes. Every node checks the signature with the master's public key. The master also requires the session to be live; a member rejects sessions it has learnt are revoked. Disabled accounts are rejected everywhere.
- Refresh tokens: 256-bit random, stored as SHA-256, valid 30 days from last use, and **rotated on every refresh**. Presenting an already rotated refresh token revokes the session (theft detection). The app serialises refreshes so it never trips this itself.
- Local device tokens from `enroll` keep working for operators and automated tests.

**Sessions and administration.** Each sign-in is a device session (device name and platform, created, last active). People list and sign out their own devices and change their password (other sessions end). Organization admins invite people (a seeded person or someone new), issue password-reset codes, disable and re-enable accounts (sessions end; admins cannot disable themselves), see and end any device session, rename the company, and create or revoke member nodes. Invitation and reset codes are single-use, valid 7 days, and replace any earlier unused code for the person. A local operator can issue one without signing in (`office-node account-code ACTOR`), which is the recovery path when no admin can sign in. Every change is written to the security audit, and every revocation advances the realtime epoch so presence tickets and voice rooms end at once.

**App.** The sign-in panel offers sign-in, "Set up company" on a new node, "I have a code" for invitations and resets, and "Use a device token". The refresh token is stored in the macOS login keychain (legacy file-based keychain, so no Keychain Sharing entitlement or provisioning profile is needed), keyed by node address; the app signs in again on launch and deletes the entry on sign-out. Access tokens live only in memory. A request that gets 401 refreshes once and retries; a refused refresh signs the app out with a notice. Workspace tools gain "Account & devices", and for admins "People & invitations" and "Company & nodes".

## Limits

- **Loopback only.** The app talks to its local node and a member talks to a master on `127.0.0.1`. Plaintext HTTP never leaves the machine; another machine's master is reached through an SSH tunnel. There is no TLS, so a direct LAN or internet deployment is out of scope.
- **Member outage behaviour.** While the master is unreachable, members accept access tokens already issued until they expire (at most 10 minutes) and refuse new sign-ins. Revocation reaches a member within one sync (5 s observed); a stopped member learns nothing until it syncs again.
- **Keys and backups.** The signing key and password hashes are in the master's database and its backups. Restoring an old backup can bring back revoked sessions. There is no key rotation; changing the key signs everyone out.
- **No second factor, email or self-service reset.** Resets go through an admin or the local operator.
- **Keychain prompts.** Debug builds are ad-hoc signed, so after a rebuild macOS may ask once whether the new build may read the stored session.
- **Not reviewed.** No external security review, rate limiting beyond per-account lockout, or audit export.

## Verification

- Rust: token signing, expiry and tampering; salted Argon2id; code format and normalisation; username and master-address rules (`cargo test`).
- `backend/office-node/tests/auth_flow.py` (HTTP, two real nodes): setup code printed and replaced, single setup, first admin; case-insensitive sign-in, generic failures, lockout after 5 failures, operator reset; refresh rotation and reuse detection; tampered tokens; invitations for seeded and new people, single use, admin only; device revoke by owner and admin, password change, disable/enable, sign-out, realtime tickets, legacy token. Federation: join code single use, forwarded sign-in and invitations, tokens checked on both nodes, new people synced, revocation seen on the member after 5.0 s, disable synced, sign-out through the member effective at once, master outage (existing tokens work, sign-in returns 502), node revocation stops sync.
- `backend/office-node/tests/sign_in_app.py` (macOS app, real keychain): company setup through the dialog, invitation issued and redeemed, device list, wrong password message, password sign-in, session restored from the keychain after the app is rebuilt, keychain entry removed by sign-out; the node shows every signed-out session revoked.
- `test/auth_session_test.dart`: keychain restore and rotation saving, one refresh for concurrent callers, revoked session signs out, unreachable node keeps the session, sign-out, device tokens never stored.
- Not verified: two physical machines over an SSH tunnel, keychain behaviour of a release-signed build, any platform other than macOS.
