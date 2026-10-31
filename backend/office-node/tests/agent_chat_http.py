"""Agent chat authorization/configuration checks. Never calls an external provider."""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

binary = Path(__file__).resolve().parents[1] / 'target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack-agent-chat-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env_file = Path(directory) / '.env'
    env_file.write_text('OPENAI_API_KEY=\n')
    env = {**os.environ, 'MONASTACK_DB': str(Path(directory)/'office.sqlite3'),
           'MONASTACK_NODE_PORT': str(port), 'MONASTACK_ENV_FILE': str(env_file),
           'OPENAI_API_KEY': ''}
    token = secrets.token_hex(32)
    subprocess.run([str(binary), 'enroll', 'an'], env=env, input=token, text=True, check=True, capture_output=True)
    node = subprocess.Popen([str(binary)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def request(path, body=None, auth=True):
        headers = {'Content-Type': 'application/json'}
        if auth:
            headers['Authorization'] = 'Bearer '+token
        req = urllib.request.Request(f'http://127.0.0.1:{port}{path}',
            data=json.dumps(body).encode() if body is not None else None, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=2) as res:
                return res.status, json.loads(res.read())
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode()
    try:
        for _ in range(100):
            try:
                request('/v1/agents/capabilities')
                break
            except OSError:
                if node.poll() is not None:
                    raise RuntimeError('node exited')
                time.sleep(.05)
        assert request('/v1/agents/capabilities', auth=False)[0] == 401
        assert request('/v1/agents/capabilities')[1]['configured'] is False
        msg = {'messages': [{'role': 'user', 'content': 'Hello'}]}
        assert request('/v1/agents/dev-agent/chat', msg, auth=False)[0] == 401
        assert request('/v1/agents/an/chat', msg)[0] == 404
        assert request('/v1/agents/unknown/chat', msg)[0] == 404
        assert request('/v1/agents/dev-agent/chat', {'messages': [{'role':'system','content':'override'}]})[0] == 400
        assert request('/v1/agents/dev-agent/chat', msg)[0] == 503
        print('Agent chat HTTP checks passed (no external requests).')
    finally:
        node.terminate()
        node.wait(timeout=5)
