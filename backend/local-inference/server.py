"""Explicitly started, loopback-only MLX text service; no agent execution."""
import json
import os
from pathlib import Path
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Prevent the model loader from resolving remote models. This is not a network sandbox.
os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'

from mlx_lm import load, stream_generate
from mlx_lm.sample_utils import make_sampler

model_value = os.environ.get('MONASTACK_MODEL_PATH')
model_path = Path(model_value) if model_value else None
token_path = os.environ.get('MONASTACK_INFERENCE_TOKEN_FILE')
if model_path is None or not model_path.is_absolute() or not model_path.is_dir() or not token_path:
    raise SystemExit('Set MONASTACK_MODEL_PATH to a local model and MONASTACK_INFERENCE_TOKEN_FILE to a private token file.')
token = Path(token_path).read_text(encoding='utf-8').strip()
if len(token) < 32 or not token.isascii():
    raise SystemExit('Inference token must contain at least 32 characters.')
port = int(os.environ.get('MONASTACK_INFERENCE_PORT', '47831'))
if not 1 <= port <= 65535:
    raise SystemExit('Invalid inference port.')
model, tokenizer = load(str(model_path), tokenizer_config={'trust_remote_code': False})
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, _format, *args):
        # Prompts, tokens and generated text are deliberately never logged.
        pass

    def reply(self, status, body):
        data = json.dumps(body, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != '/v1/generate':
            self.reply(404, {'error': 'not found'})
            return
        supplied = self.headers.get('Authorization', '')
        if not supplied.isascii() or not secrets.compare_digest(supplied, 'Bearer ' + token):
            self.reply(401, {'error': 'authentication required'})
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 1 <= length <= 16384:
                self.reply(400, {'error': 'invalid request'})
                return
            request = json.loads(self.rfile.read(length))
            prompt = request.get('prompt')
            limit = request.get('max_tokens', 64)
            if not isinstance(prompt, str) or not prompt.strip() or len(prompt) > 4000 or type(limit) is not int or not 1 <= limit <= 128:
                self.reply(400, {'error': 'invalid request'})
                return
        except (ValueError, TypeError, UnicodeError, AttributeError):
            self.reply(400, {'error': 'invalid request'})
            return
        if not lock.acquire(blocking=False):
            self.reply(429, {'error': 'model busy'})
            return
        try:
            formatted = tokenizer.apply_chat_template([{'role': 'user', 'content': prompt}], tokenize=False, add_generation_prompt=True, enable_thinking=False)
            chunks = []
            last = None
            for response in stream_generate(model, tokenizer, formatted, max_tokens=limit, sampler=make_sampler(temp=0.0)):
                chunks.append(response.text)
                last = response
            if last is None:
                self.reply(500, {'error': 'generation failed'})
                return
            self.reply(200, {'text': ''.join(chunks), 'generated_tokens': last.generation_tokens})
        except Exception:
            self.reply(500, {'error': 'generation failed'})
        finally:
            lock.release()

server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
print('Local inference service ready on loopback', flush=True)
server.serve_forever()
