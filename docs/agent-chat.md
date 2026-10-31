# Agent chat

The macOS agent chat uses authenticated POST SSE from the office node. Member
nodes forward the response body without buffering. OpenAI credentials stay on
the master; requests use Responses API with `store: false`.

## Protocol and lifecycle

POST `/v1/agents/{agent}/chat` with the existing messages/UI context plus
`"stream": true`. Without that flag, existing JSON clients remain supported.
The legacy direct Mona administration tool loop remains JSON-only; streaming
clients operate the app through the authenticated `ui_controls` tool instead.

- `delta`: `{"text":"..."}` — visible answer/refusal content, never reasoning.
- `done`: the existing final response (text/model/incomplete or a validated UI
  action, call ID and continuation history).
- `error`: `{"status":502}` or another sanitized HTTP-equivalent status.

HTTP validation/authentication failures occur before SSE starts. EOF without
`done` is a failure. The parser handles arbitrary UTF-8 boundaries, LF/CRLF and
heartbeat comments. Provider requests have a 55-second deadline; the member
allows 65 seconds and the client imposes 70 seconds overall.

Stop, closing chat and signing out cancel the dedicated HTTP request. Dropping
the response drops the provider stream and releases its concurrency permit.
Cancellation does not undo UI actions that have already run. Interrupted action
requests are never automatically replayed; the composer is cleared after an
action-related interruption so the user can inspect the screen first.

Tool arguments are only accepted from a terminal, completed provider response.
The requested control must exist in the supplied snapshot. The UI executes one
control, reports its result, refreshes controls, then requests the next stream.
A maximum of ten UI steps applies per user turn.

## Chat behavior

Conversations are separate per agent and last while the dialog is open. The
request includes at most ten previous turns, within the backend byte budget.
Interrupted partial answers remain visible until retry or switching agents and
are excluded from model context. Rendering is batched at 40 ms; automatic
scrolling follows only when the reader is near the bottom.

Markdown supports selectable text and code, copy, and user-clicked HTTP(S)
links. Remote images are not automatically fetched. Enter sends; Shift+Enter
adds a line; active IME composition is preserved.

## Manual checks

1. Open Chat with agents, select Atlas, and ask for a multi-step plan. Confirm
   the user message appears immediately and the response grows before finishing.
2. Ask for a longer answer and press Stop. Verify partial text remains; edit and
   resend. The old generation must not add text to the new answer.
3. Ask for a Markdown table and a long code block. Resize the window and copy the
   answer. Scroll up during generation; it should not pull you back down.
4. Switch agents and verify their histories are separate. Use New conversation
   to reset the selected agent's history.
5. Ask “Open the task board.” Verify the board opens once and the agent reports
   the result. Interrupt an action request and inspect the screen before retrying.
6. Disconnect the network during an answer. Verify an interruption appears and
   the partial answer is not treated as a successful completed turn.
7. Close the dialog or sign out during generation; reopen and start a fresh chat.

Reference: https://developers.openai.com/api/docs/guides/streaming-responses
