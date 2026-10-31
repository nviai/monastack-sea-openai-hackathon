# Codex integration evaluation

The process-host experiment accepts an explicitly configured fixed command in a networkless container with an empty temporary directory. It does not provide a production Codex adapter, repository access, provider credentials, model budget enforcement, or verified agent work. A command's successful exit and host report are not proof of an agent result.

OpenAI documents `codex exec` as an integration surface for bounded non-interactive workflows, while model access and the harness are separate concerns: [Codex as a platform](https://developers.openai.com/blog/codex-as-a-platform). The locally installed CLI exposes local-provider options, but their presence does not establish a working model or a safe integration. The existing MLX text-generation experiment has not been established as compatible with Codex's provider protocol.

On 2026-10-29, an image export initially failed with a Docker Desktop I/O error while the system volume had approximately 236 MiB free. When space later became available, the image built successfully. The image contains the pinned `@openai/codex` 0.164.0 CLI and a deliberately fake localhost model service, with only the synthetic test files included in its build context. The worker test submitted a synthetic approved job to an isolated node, started the real Codex CLI with `--oss`, `--local-provider lmstudio`, `--ignore-user-config` and `--ephemeral` inside a networkless container, received the service's fixed response and recorded an unverified host report. The service does not perform inference. No real model, credentials, repository, or workspace data were sent to the test. The CLI warned that it used bundled bubblewrap and fallback model metadata. The experiment establishes neither model quality nor safety for real tasks.

To reproduce from the repository root, build the small restricted context and pass its resulting image ID to the synthetic worker test:

```sh
docker build -t monastack-codex-synthetic:local tools/codex-spike
MONASTACK_SYNTHETIC_CODEX_IMAGE="$(docker image inspect monastack-codex-synthetic:local --format '{{.Id}}')" python3 backend/process-node/test_worker.py
```

The build downloads public package dependencies; the subsequent test uses no external container networking. The opt-in `--codex-state-tmpfs` worker flag supplies an ephemeral, size-limited `/.codex` for this image's non-root user. It is not a credential store. The standard worker deadline, cancellation control and watchdog apply, but the test does not demonstrate a real provider or real code modification. A real provider and clearly scoped workspace require explicit configuration and authorization; network and credential handling, project isolation, actual output verification, cancellation, spending limits and audit behavior need further design and tests before treating a Codex host as operational.
