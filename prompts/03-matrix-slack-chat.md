# Prompt: Implement Matrix chat with a complete Slack-style experience

Use this prompt in a new development session. This task replaces the chat core; it does not implement any other future stage.

---

Continue developing Monastack in this repository. The current workspace is `/Users/phale/hackathon/monastack-sea-openai-hackathon`; use the actual checkout root if it differs.

Implement Matrix as the chat core, with a complete Slack-style experience integrated into the Flutter macOS application. Deliver working code and validation, not just an architecture proposal or mockup.

## 1. Understand the existing application

Before changing anything, read applicable `AGENTS.md` files, `README.md`, current ADRs and runbooks, relevant source and tests, and `git status`. Preserve existing user changes. Current source and this request take precedence over outdated documentation.

The current implementation includes:

- Flutter, Riverpod and Flame for the application, with a Rust core and an `office-node` backend.
- A shared server authority. Member nodes forward office requests to the server by default.
- Custom text-chat APIs backed by SQLite and refreshed by polling every five seconds.
- Existing `room:<room-id>` and direct-message scopes. Room chat is already logically scoped; its small conversation panel follows the avatar's current room.
- One shared LiveKit server for voice and camera, with a shared presence service.
- A sign-in screen before authentication; the office is shown only after the node verifies the user.
- A Workspace tools button on the left of the map toolbar, on the same row as the zoom controls.
- Runtime configuration and persistent service data under the Git-ignored `runtime/` directory.
- Seeded human accounts and agents. Read the current source for their username and role mappings rather than relying on old examples.

The current local server address is `192.168.224.217`. Office API uses port `47830`, shared presence uses `47831`, the local member API uses `47840`, and LiveKit uses signaling port `7880`, RTC TCP port `7881`, and UDP port `7882`. Treat these as configurable deployment values, not permanent application constants.

## 2. Required product experience

Add a **Chat** entry to Workspace tools. Opening it must display a large Slack-style chat dialog inside the existing application:

- Do not open a browser or an external chat application.
- Do not require a separate Matrix login.
- Support an appropriately resizable or expandable macOS dialog.
- Follow the application's existing visual design and color palette.
- Keep all default interface text in English.

The layout should provide:

- A sidebar with search, Unreads, Mentions, Channels and Direct messages.
- A main pane with the conversation header, message history and composer.
- A secondary pane for an open thread, room details or member list.
- Clear loading, empty, error, retry and reconnect states.

### Independent room chat spaces

Each office room must have its own Matrix room with a durable server-side mapping:

- All clients share the same mapping.
- Never create a separate Matrix room per client, per dialog opening, or per application restart.
- Never use one Matrix room for every office room.
- Use stable office room IDs for the mapping, not display names.
- Renaming an office room must preserve its conversation history.

Chat navigation must be independent of avatar movement:

- Users can read and post in any channel they are authorized to access without walking their avatar into it.
- Walking to another office room must not discard the selected channel, thread or draft.
- Provide an action to open the current office room's chat.
- If the small Room conversation panel is retained, it must use the same Matrix-backed conversations. Do not maintain a second, divergent chat system.

## 3. Required chat capabilities

### Channels

- Show authorized channels with names, descriptions/topics, unread counts and mention badges.
- Support channel switching and mark-as-read.
- Provide room information and member lists.
- Distinguish open and restricted rooms.

### Messages

- Persist history and load older messages when scrolling upward.
- Receive new events through Matrix synchronization rather than the old chat polling loop.
- Provide optimistic sending and sending/sent/failed/retry states.
- Prevent duplicate sends on retry or reconnect.
- Support replies, threads and reactions.
- Support message editing and deletion/redaction according to permissions, with visible edited/deleted states.
- Render basic Markdown, code blocks and links, and support copying text.
- Upload images and files, show appropriate previews, and support downloading attachments.
- Support user mentions, typing indicators and read/unread state.
- Implement actual message search within the supported backend capabilities. Do not present filtering only the currently loaded page as a full-history search feature.

### Direct messages

- Support one-to-one and group DMs.
- Reuse existing conversations instead of creating duplicates.
- Provide a DM list, unread state and a person picker to start conversations.

### Composer

- Support multiline drafts, Enter to send and Shift+Enter for a newline.
- Provide attachment controls and upload progress/error states.
- Provide cancellable reply and edit modes.
- Preserve separate drafts for channels, DMs and threads.
- Preserve content when sending fails.
- Support appropriate macOS keyboard shortcuts.

### Notifications

- Show unread and mention badges inside the dialog.
- Show a badge on the Workspace tools Chat entry when there are unread messages.
- Provide desktop notifications within operating-system permission rules.
- Do not expose restricted content through notifications after the user's access has been revoked.

Do not simulate missing backend features with fake data or controls that claim success without doing the work.

## 4. Matrix backend and deployment topology

Deploy an appropriate self-hosted Matrix homeserver. Prefer Synapse unless a concrete technical reason justifies another choice.

- Consult current official Matrix, homeserver and SDK documentation before choosing the integration approach.
- Select a maintained Flutter/macOS-compatible SDK that supports the required behavior.
- Pin dependencies and container images to specific versions.
- Manage the homeserver and its database with the project's Docker/startup workflow.
- Persist configuration, homeserver database data and media storage under `runtime/`.
- Keep generated credentials and runtime data out of committed source.
- Do not enable external federation or send workspace data to a public Matrix service without an explicit requirement.

Use one shared homeserver for the workspace. The node server owns provisioning and mappings. Member/client nodes must not run independent homeservers.

Matrix owns text chat and its associated content. LiveKit continues to own voice and video. Preserve the current microphone/camera controls and the ability to enable them directly from the lobby.

## 5. Identity and authorization

Reuse the existing Monastack sign-in and accounts:

- Maintain a durable actor-ID-to-Matrix-user-ID mapping independent of display names.
- Do not ask users to know or enter a Matrix password.
- Do not share one Matrix user account among all humans.
- Do not arbitrarily reuse Monastack user passwords as Matrix credentials.
- Keep homeserver administration credentials on the backend.
- Handle user tokens within their intended scopes and store them appropriately. Never log tokens or private conversation content.

Derive room membership from office permissions:

- Only authorized users may join and read restricted rooms.
- Enforce access revocation at the homeserver/backend, not only by hiding a channel in Flutter.
- Apply authorization to history, search, attachments and threads as well as new messages.
- Define history visibility for newly admitted members explicitly.
- Do not grant HR or Finance access merely because someone's title is CEO or CTO.
- Do not infer global Matrix administration privileges from a displayed job title.

Choose encryption behavior deliberately, accounting for the application's current server-readable data model. Document whether E2EE is enabled. Do not claim E2EE unless device keys, verification, recovery and their lifecycle are actually implemented and tested.

## 6. Transition from the existing chat implementation

Inspect the current database, APIs and local outbox before selecting a migration strategy.

- Back up existing data before migration.
- Either implement a one-time import where feasible, or retain clearly identified read-only legacy history.
- Do not impersonate original senders or falsify timestamps during import.
- Make import/mapping operations idempotent, checkpointed and safe to resume without duplicates.
- Do not leave the composer writing simultaneously to the old SQLite chat and Matrix.
- Handle pending legacy outbox entries explicitly. Do not silently discard them or replay them into the wrong conversation.
- Preserve unrelated record IDs and business data.

## 7. Operational integration and documentation

Update:

- `tools/local_office.py` so start/status/stop manage Matrix as part of the stack.
- `tools/start-client.sh` as needed so LAN clients can use the complete chat experience.
- The `runtime/` layout and `.env.example`.
- Setup, run, test and recovery instructions.
- ADRs describing topology, identity, mappings, permissions, token handling, migration and known limitations.

A client machine should only need the application and server connectivity, not a separate homeserver or homeserver administration credentials.

Do not hardcode secrets, generated user IDs or generated Matrix room IDs in the app. Make example network addresses configurable for other machines.

## 8. Validation and completion criteria

Validate with two independent clients/accounts:

- Users in the same channel see the same persistent history and receive new messages through Matrix synchronization.
- Different office rooms never mix their messages.
- Users can chat in an authorized channel while their avatar is elsewhere.
- One-to-one and group DMs work and are not visible to outsiders.
- Threads, reactions, edits, deletion and file upload/download work.
- Unread state, mentions, read state and reconnect behavior work.
- Network loss and retries do not duplicate messages or discard drafts.
- Revoking access prevents further reading, posting and content downloads according to the documented policy.
- Restarting the app, nodes or homeserver preserves history and does not duplicate users or rooms.
- LAN clients work with the current server configuration.
- Existing LiveKit voice/camera and unrelated office features still work.

Run appropriate automated tests, Flutter Analyze and a macOS build. Use the real homeserver/SDK for integration validation, not only mocks.

Do not turn on real microphones or cameras merely to run tests. Use synthetic media or capture-disabled connections when device capture is unnecessary.

On completion, report:

- Implemented behavior and how to use it.
- How to start and operate the services.
- Tests actually executed and their results.
- Data migrations actually performed.
- Remaining limitations or unfinished behavior, clearly separated from working functionality.

Do not commit or push unless explicitly requested.
