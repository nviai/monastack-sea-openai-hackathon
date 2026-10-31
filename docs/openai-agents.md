# OpenAI office chat

The office node calls the OpenAI Responses API over HTTPS. All authenticated human office members can talk to Mona, Dev, QA, PM, Sales and Customer Support agents. Each agent has a server-defined specialty. This chat does not execute approved jobs or use workspace action tools.

## Setup

Fill in the prepared `runtime/.env`:

```dotenv
OPENAI_API_KEY=your-key-here
OPENAI_MODEL=gpt-4.1-mini
```

The key stays on the backend and `.env` is ignored by Git. Never put it in Flutter assets or Dart defines. Existing process environment variables take precedence over `.env` values. The node loads `runtime/.env` under the repository root, with the old root `.env` as a compatibility fallback. Set `MONASTACK_RUNTIME_DIR` to override the runtime root. For a different launch directory, use `MONASTACK_ENV_FILE=/absolute/path/to/runtime/.env`.

Restart the office node after changing credentials. From the repository root:

```sh
cargo run --manifest-path backend/office-node/Cargo.toml
```

Use the existing node/database/port settings if already configured. Sign in to the office app, click an agent in the office or People & agents, then choose **Chat with agent**. Alternatively open workspace tools → **Chat with agents**. Each user request uses the existing authenticated node connection. The model can be changed to a Responses-compatible model available to your OpenAI project using `OPENAI_MODEL`.

## Behavior and limits

- Only the chosen agent's recent conversation is sent to OpenAI. No repository files, rooms, tasks, documents or other users' messages are automatically included.
- Conversation histories are separate per agent and live in the open chat window's memory; closing it clears them. The most recent ten turns are included, within backend byte limits.
- OpenAI requests use `store: false`; this does not change OpenAI's separate abuse monitoring or organization data policies.
- Up to four provider requests can run concurrently per office-node process. Each request has a 55-second provider timeout and a 2,048 output-token cap. Provider quota and rate-limit failures are shown in the app. These are request bounds, not a monthly spending cap.
- Keys and raw provider errors are never returned to the client. Authentication, human identity and agent identity are checked before calling OpenAI; authentication is checked again before returning the result.
- Text replies appear when the response finishes. This integration does not enable microphone calls, streaming voice or autonomous tool execution. Agent avatars remain seeded profiles rather than human presence connections.

Reference: [OpenAI Responses API](https://developers.openai.com/api/reference/python/resources/responses/methods/create).
