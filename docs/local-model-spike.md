# Local model spike

This is a standalone measurement and an optional local text-generation adapter, not an assistant or agent. On October 28, 2026, a synthetic one-sentence summarization prompt was run locally on a Mac mini with Apple M6, 32 GiB memory, macOS 27.0.1, native Python 3.12.15, `mlx-lm` 0.32.2 and MLX 0.32.4. The model was [`mlx-community/Qwen3-0.6B-4bit`](https://huggingface.co/mlx-community/Qwen3-0.6B-4bit) at revision `73e3e38d981303bc594367cd910ea6eb48349da8`; its model page lists Apache-2.0. The downloaded cache occupied approximately 335 MiB. No NVIAI records or other user data were used as input.

One run loaded the model in 0.316 s and completed generation in 1.528 s. MLX reported 34 prompt tokens at 23.15 tokens/s and 16 generated tokens at 351.67 tokens/s, with 0.504 GB peak MLX memory. The process reported 702.3 MB peak resident memory. The response repeated the synthetic one-sentence input. This is one warm-cache measurement, not a quality evaluation, sustained throughput guarantee, hardware minimum, or proof that the model is suitable for company data.

## Reproduce

The model and virtual environment are ignored by Git. Install dependencies into an isolated environment and download the pinned public snapshot; these commands contact package and model hosts, but do not send workspace records. Review dependencies and model license before use:

```sh
uv venv --python 3.12 tools/local-model/.venv
uv pip install --python tools/local-model/.venv/bin/python -r tools/local-model/requirements.lock
HF_HOME="$PWD/tools/local-model/cache/hf" HF_HUB_DISABLE_TELEMETRY=1 tools/local-model/.venv/bin/python -c "from huggingface_hub import snapshot_download; print(snapshot_download(repo_id='mlx-community/Qwen3-0.6B-4bit', revision='73e3e38d981303bc594367cd910ea6eb48349da8', allow_patterns=['*.json','*.safetensors','*.model','*.txt','README.md']))"
HF_HOME="$PWD/tools/local-model/cache/hf" tools/local-model/.venv/bin/python tools/local-model/benchmark.py
```

The benchmark loads the pinned local path, disables Hugging Face network lookup and telemetry through environment flags, disables remote model code, and uses a fixed synthetic input. These flags are not an OS-level network sandbox. The script reports its own metrics and output. The benchmark itself does not read documents, call the node, expose an endpoint or run as Mona. The optional service below accepts only a user-supplied prompt and has no automatic document access. Further work is needed on permissions, data handling, isolation, cancellation, quality evaluations and resource limits.

## Optional local text service

The local service uses the same pinned model and a separate random token. It binds only to `127.0.0.1:47831`, does not read workspace records, and does not log prompts, responses or credentials. It accepts one generation at a time, limits prompts to 4,000 characters and output to 128 tokens, and does not run agents or take actions. The loopback protocol is unencrypted and the service is not OS-network-sandboxed; it is a development prototype, not a production boundary. Do not use it for confidential material without the missing security review.

From the repository root, after downloading the model as above:

```sh
umask 077
openssl rand -hex 32 > local-inference-token.txt
MONASTACK_MODEL_PATH="$PWD/tools/local-model/cache/hf/hub/models--mlx-community--Qwen3-0.6B-4bit/snapshots/73e3e38d981303bc594367cd910ea6eb48349da8" MONASTACK_INFERENCE_TOKEN_FILE="$PWD/local-inference-token.txt" HF_HOME="$PWD/tools/local-model/cache/hf" tools/local-model/.venv/bin/python backend/local-inference/server.py
```

Connect the office app to its local node, choose **Workspace tools → Local text model**, paste the separate inference token, and explicitly submit a prompt. The token file is private and ignored by Git. `python3 backend/local-inference/test_server.py --app` starts an isolated service with a temporary token and port, tests authorization and synthetic generation, and runs the macOS screen integration test. It does not send workspace data. The app test runner reported that it could not foreground the app, but the test completed.
