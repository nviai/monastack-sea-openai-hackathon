"""Run the configured model on synthetic text with an isolated local service."""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import sys
import urllib.error
import urllib.request

root = Path(__file__).resolve().parents[2]
python = root / 'tools/local-model/.venv/bin/python'
revision = '73e3e38d981303bc594367cd910ea6eb48349da8'
model = root / 'tools/local-model/cache/hf/hub/models--mlx-community--Qwen3-0.6B-4bit/snapshots' / revision
if not python.exists() or not model.is_dir():
    raise SystemExit('Install the pinned local model environment first; see docs/local-model-spike.md.')
with tempfile.TemporaryDirectory(prefix='monastack-inference-test-') as directory:
    token = secrets.token_hex(32)
    token_file = Path(directory) / 'token'
    token_file.write_text(token)
    token_file.chmod(0o600)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env = {**os.environ, 'MONASTACK_MODEL_PATH':str(model), 'MONASTACK_INFERENCE_TOKEN_FILE':str(token_file), 'MONASTACK_INFERENCE_PORT':str(port), 'HF_HOME':str(root/'tools/local-model/cache/hf')}
    service = subprocess.Popen([str(python), str(root/'backend/local-inference/server.py')], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        for _ in range(300):
            if service.poll() is not None:
                raise RuntimeError('Local inference service failed to start')
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.2):
                    break
            except OSError:
                time.sleep(.1)
        else:
            raise RuntimeError('Local inference service did not start')
        def request(credential, body):
            req=urllib.request.Request(f'http://127.0.0.1:{port}/v1/generate',data=json.dumps(body).encode(),headers={'Authorization':'Bearer '+credential,'Content-Type':'application/json'},method='POST')
            try:
                with urllib.request.urlopen(req, timeout=30) as res:
                    return res.status, json.load(res)
            except urllib.error.HTTPError as exc:
                return exc.code, None
        assert request('wrong',{'prompt':'test'})[0]==401
        assert request(token,{'prompt':'','max_tokens':16})[0]==400
        status, result=request(token,{'prompt':'Say hello in one short sentence.','max_tokens':32})
        assert status==200 and result['text'].strip() and result['generated_tokens']>0
        second, result=request(token,{'prompt':'Say hello again.','max_tokens':32})
        assert second==200 and result['text'].strip()
        print('Local inference: authentication, validation and synthetic generation passed')
        if '--app' in sys.argv:
            app_env = {**env, 'MONASTACK_TEST_INFERENCE_TOKEN':token}
            subprocess.run(['flutter','test','integration_test/local_inference_test.dart','-d','macos'],cwd=root/'app',env=app_env,check=True,timeout=90)
    finally:
        service.terminate()
        try:
            service.wait(timeout=10)
        except subprocess.TimeoutExpired:
            service.kill()
            service.wait(timeout=5)
