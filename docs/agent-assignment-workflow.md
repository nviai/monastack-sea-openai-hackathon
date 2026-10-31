# Agent assignment workflow

Standalone assignments create private tickets. Linked assignments retain project
access. Execution approval still requires an organization admin and a configured host.

## Clarifications

A host with a current fence posts `/v1/host/jobs/{job}/question` with `id`, `fence`,
and `question`. The node writes a ticket comment and notification, then pauses the
job in `waiting_input`. The requester replies in Notifications with up to four files
of 256 KiB each. Replies validate identity, ticket access, filenames and base64 size.
The job returns to `approved_waiting`; its next claim has a new fence and includes
question/answer history and attachments. Files are stored in SQLite and passed to
Codex under generated temporary names.

## Codex adapter

Dev and QA are the repository-capable agents. Enroll an agent-scoped host using
[host-claims.md](host-claims.md), authenticate the local Codex CLI, and run:

```sh
python3 backend/process-node/codex_worker.py \
  --node http://127.0.0.1:47830 \
  --token-file /absolute/path/to/private-host-token \
  --checkout /absolute/path/to/dedicated-checkout --watch
```

Use a separate checkout per host. Changes stay there for review; no automatic
commit, push or merge occurs. The adapter uses `codex exec`, workspace-write
sandboxing and structured output. It renews its claim every five seconds and
terminates on cancellation, authority failure or deadline (default 600 seconds).
`needs_input` creates a question; `completed` submits a report requiring user review.
The requested budget is not a monetary/token spending limit. Expired crashed jobs
are not automatically reclaimed.

On 2026-10-31, a real ChatGPT-authenticated Codex CLI created and verified hello.txt
in a temporary Git repository and returned valid structured output. Full deployed
app-to-worker integration has not been exercised. See the official
[non-interactive documentation](https://developers.openai.com/codex/noninteractive/).

## Delivery settings and voice

Admins use Notifications → Delivery settings to choose notifications or voice with
notification fallback. The live worker finds users through authenticated current
room presence and relays a generic notification reminder through the room resident
agent. Public pending questions can be asked aloud. Private ticket contents are never spoken to shared room audio. Users can ask
about their public pending questions and reply by voice; the node validates the
speaker and room lease. Overlapping/unknown speakers cannot authorize a reply.
Private replies, attachments and result acceptance/rejection use the app.

Voice requires the existing LiveKit/live worker and OpenAI setup. Durable
notifications remain available if voice cannot run. Muted microphones stay muted.

Remaining: animated assigned-agent approach, private one-to-one voice questions and
approval, non-coding autonomous workers, per-event channel preferences, attachment
download UI, and automatic worker provisioning/startup.
