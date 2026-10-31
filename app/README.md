# Monastack client

Ứng dụng office Flutter/Flame cho macOS, dùng Rust core và kết nối office node qua loopback HTTP.

Xem [hướng dẫn chạy project từ đầu](../docs/run-project.vi.md) cho cả node + app client và node server.

## Matrix chat on macOS

Sign in to Monastack, then open **Workspace tools → Chat**. The office node supplies chat configuration and a short-lived login ticket. There is no separate Matrix login. A node without chat configuration displays “Chat is not available on this server”.

Choose any authorized channel or use **Direct messages → +** to select up to eight people. Opening Chat preserves your selected conversation. **Open this room's chat** explicitly selects the avatar's current office room. Moving the avatar leaves chat selection and drafts alone.

Use the message menu for replies, threads, reactions, edits, deletion and copying. The header opens room details, members and earlier read-only history. Search submits a full-history server query. The paperclip uploads a file or image. Attachments offer previews and a save dialog.

- **Enter** sends. **Shift+Enter** inserts a newline.
- **Command+K** or **Command+F** focuses search.
- **Command+W** closes Chat. **Escape** cancels reply/edit mode.
- The expand button and bottom-right drag handle resize the dialog.
- The bell requests notification permission. Notifications contain no conversation previews and only appear for mentions or DMs while the app is unfocused.
- Failed messages keep their drafts. **Retry send** reuses the original transaction.
- **Earlier messages not sent** offers copy-only recovery for the old queue. Nothing in that queue is replayed into Matrix.

Drafts and pending Matrix sends survive conversation changes and dialog closure within the current signed-in app session. They are held in memory and do not survive process termination or sign-out. History remains on the shared homeserver and is reloaded through synchronization and pagination.

The client uses `matrix` **14.2.0**, licensed **AGPL-3.0**. Encryption is off. Its SQLite database is ephemeral, while device tokens persist in the existing platform keychain per node and actor. No homeserver administration credential belongs on a client.

Use the prescribed toolchain for validation:

```sh
export PATH="$HOME/fvm/versions/3.47.7/bin:$PATH"
flutter analyze
flutter test
flutter build macos --debug
```

Run those commands from `app/`. Native bridge tests require the Rust core build described in the repository setup instructions. Service deployment and real two-account validation belong to the server and integration lanes. Real two-account validation is tracked by the integration lane.
