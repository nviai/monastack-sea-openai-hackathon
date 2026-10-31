"""Exercise scoped, ordered chat-history pagination against a disposable node."""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

root = Path(__file__).resolve().parents[3]
node = root / 'backend/office-node/target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack-chat-history-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    tokens = {actor: secrets.token_hex(32) for actor in ('an', 'van')}
    env = {**os.environ, 'MONASTACK_DB': str(Path(directory) / 'office.sqlite3'), 'MONASTACK_NODE_PORT': str(port)}
    for actor, token in tokens.items():
        subprocess.run([str(node), 'enroll', actor], env=env, input=token, text=True, check=True)
    server = subprocess.Popen([str(node)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        def request(actor, method, path, body=None):
            req = urllib.request.Request(f'http://127.0.0.1:{port}/v1/{path}', method=method,
                data=None if body is None else json.dumps(body).encode(),
                headers={'Authorization': 'Bearer ' + tokens[actor], 'Content-Type': 'application/json'})
            try:
                with urllib.request.urlopen(req, timeout=3) as response:
                    raw = response.read()
                    return response.status, json.loads(raw) if raw else None
            except urllib.error.HTTPError as error:
                return error.code, None
        for _ in range(100):
            if server.poll() is not None:
                raise RuntimeError('node failed')
            try:
                if request('an', 'GET', 'me')[0] == 200:
                    break
            except OSError:
                time.sleep(.05)
        else:
            raise RuntimeError('node did not start')
        for index in range(205):
            msg = {'id': f'synthetic+message-{index:04d}', 'body': f'synthetic message {index}'}
            assert request('an', 'POST', 'messages/room%3Alobby', msg)[0] == 201
        private = {'id': 'synthetic-private-0001', 'body': 'synthetic private'}
        assert request('van', 'POST', 'messages/room%3Afinance', private)[0] == 201
        status, latest = request('an', 'GET', 'messages/room%3Alobby')
        assert status == 200 and len(latest) == 200 and latest[0]['id'] == 'synthetic+message-0005'
        cursor = urllib.parse.quote(latest[0]['id'], safe='')
        status, older = request('an', 'GET', 'messages/room%3Alobby?before=' + cursor)
        assert status == 200 and [entry['id'] for entry in older] == [f'synthetic+message-{index:04d}' for index in range(5)]
        assert request('an', 'GET', 'messages/room%3Alobby?before=synthetic-private-0001')[0] == 404
        assert request('an', 'GET', 'messages/room%3Afinance?before=synthetic-private-0001')[0] == 403
        subprocess.run([str(node), 'room', 'revoke', 'finance', 'van'], env=env, check=True)
        assert request('van', 'GET', 'messages/room%3Afinance?before=synthetic-private-0001')[0] == 403
        print('Chat history: ordered pages, encoded cursors, scope isolation and revocation passed')
    finally:
        server.terminate()
        server.wait(timeout=5)
