"""Offline, synthetic-input MLX spike. Never reads workspace records."""
import json
import os
from pathlib import Path
import platform
import resource
import time

os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
from mlx_lm import load, stream_generate
from mlx_lm.sample_utils import make_sampler

REVISION = '73e3e38d981303bc594367cd910ea6eb48349da8'
MODEL = Path(__file__).resolve().parent / 'cache/hf/hub/models--mlx-community--Qwen3-0.6B-4bit/snapshots' / REVISION
if not MODEL.is_dir():
    raise SystemExit('Pinned model snapshot is absent; see docs/local-model-spike.md.')
start = time.perf_counter()
model, tokenizer = load(str(MODEL), tokenizer_config={'trust_remote_code': False})
loaded = time.perf_counter()
prompt = tokenizer.apply_chat_template(
    [{'role': 'user', 'content': 'Summarize in one sentence: A fictional bakery ordered twelve boxes on Monday and received all twelve on Tuesday.'}],
    tokenize=False, add_generation_prompt=True, enable_thinking=False,
)
parts = []
last = None
for response in stream_generate(model, tokenizer, prompt, max_tokens=80, sampler=make_sampler(temp=0.0)):
    parts.append(response.text)
    last = response
finished = time.perf_counter()
if last is None or not ''.join(parts).strip():
    raise SystemExit('Model produced no text.')
print(json.dumps({
    'model': 'mlx-community/Qwen3-0.6B-4bit',
    'revision': REVISION,
    'python': platform.python_version(),
    'load_seconds': round(loaded - start, 3),
    'generation_seconds': round(finished - loaded, 3),
    'prompt_tokens': last.prompt_tokens,
    'generation_tokens': last.generation_tokens,
    'prompt_tokens_per_second': round(last.prompt_tps, 2),
    'generation_tokens_per_second': round(last.generation_tps, 2),
    'mlx_peak_gb': round(last.peak_memory, 3),
    'process_peak_rss_mb': round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1_000_000, 1),
    'synthetic_response': ''.join(parts),
}, ensure_ascii=False, indent=2))
