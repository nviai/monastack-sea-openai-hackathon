#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
python3 -m venv "$ROOT/runtime/live-agent/.venv"
"$ROOT/runtime/live-agent/.venv/bin/pip" install -r "$ROOT/backend/live-agent/requirements.lock"
