"""Exercise scoped chat history and revocation in an isolated macOS app."""
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

# The app signs in with the enrolled device token, not a password (ADR 0008).
os.environ.setdefault('MONASTACK_SIGN_IN', 'token')

root = Path(__file__).resolve().parents[3]
node = root / 'backend/office-node/target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack-chat-history-app-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    token = secrets.token_hex(32)
    env = {**os.environ, 'MONASTACK_DB': str(Path(directory) / 'office.sqlite3'),
           'MONASTACK_NODE_PORT': str(port), 'MONASTACK_TEST_TOKEN': token,
           'MONASTACK_TEST_ISOLATED_OUTBOX': '1'}
    subprocess.run([str(node), 'enroll', 'van'], env=env, input=token, text=True, check=True)
    server = subprocess.Popen([str(node)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    stop = threading.Event()
    errors = []
    watcher = None
    try:
        def request(method, path, body=None):
            req = urllib.request.Request(f'http://127.0.0.1:{port}/v1/{path}', method=method,
                data=None if body is None else json.dumps(body).encode(),
                headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
            with urllib.request.urlopen(req, timeout=3) as response:
                return response.status
        for _ in range(100):
            if server.poll() is not None:
                raise RuntimeError('node failed')
            try:
                if request('GET', 'me') == 200:
                    break
            except OSError:
                time.sleep(.05)
        else:
            raise RuntimeError('node did not start')
        for index in range(205):
            assert request('POST', 'messages/room%3Afinance',
                {'id': f'synthetic-history-{index:04d}', 'body': f'synthetic history {index}'}) == 201
        def revoke_on_marker():
            try:
                while not stop.wait(.1):
                    with sqlite3.connect(env['MONASTACK_DB'], timeout=2) as connection:
                        found = connection.execute("SELECT 1 FROM messages WHERE body='synthetic history revoke'").fetchone()
                    if found:
                        subprocess.run([str(node), 'room', 'revoke', 'finance', 'van'], env=env, check=True)
                        return
            except Exception as error:
                errors.append(error)
        watcher = threading.Thread(target=revoke_on_marker, daemon=True)
        watcher.start()
        test = subprocess.Popen(['flutter', 'test', 'integration_test/chat_history_test.dart', '-d', 'macos'],
                                cwd=root / 'app', env=env, start_new_session=True)
        try:
            code = test.wait(timeout=180)
        except subprocess.TimeoutExpired:
            os.killpg(test.pid, signal.SIGKILL)
            test.wait(timeout=5)
            raise
        if code:
            raise subprocess.CalledProcessError(code, test.args)
        with sqlite3.connect(env['MONASTACK_DB']) as connection:
            verified = connection.execute("SELECT 1 FROM messages WHERE body='synthetic history verified'").fetchone()
        if errors or not verified:
            raise RuntimeError('chat history revocation was not verified') from (errors[0] if errors else None)
    finally:
        stop.set()
        if watcher is not None:
            watcher.join(timeout=5)
        server.terminate()
        server.wait(timeout=5)
