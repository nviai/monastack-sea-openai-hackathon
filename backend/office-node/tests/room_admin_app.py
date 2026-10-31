"""Test authenticated room administration through an isolated macOS app."""
import os
from pathlib import Path
import secrets
import signal
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

root = Path(__file__).resolve().parents[3]
node = root / 'backend/office-node/target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack-room-admin-app-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    token = secrets.token_hex(32)
    env = {**os.environ, 'MONASTACK_DB': str(Path(directory) / 'office.sqlite3'),
           'MONASTACK_NODE_PORT': str(port), 'MONASTACK_TEST_TOKEN': token,
           'MONASTACK_TEST_ISOLATED_OUTBOX': '1'}
    subprocess.run([str(node), 'enroll', 'an'], env=env, input=token, text=True, check=True)
    server = subprocess.Popen([str(node)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if server.poll() is not None:
                raise RuntimeError('node failed')
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{port}/v1/me', timeout=.2)
            except urllib.error.HTTPError:
                break
            except OSError:
                time.sleep(.05)
        else:
            raise RuntimeError('node did not start')
        test = subprocess.Popen(['flutter', 'test', 'integration_test/room_admin_test.dart', '-d', 'macos'],
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
            actions = connection.execute("SELECT action FROM security_audit WHERE actor='an' AND subject='an' AND action IN ('room_grant:finance','room_revoke:finance') ORDER BY seq").fetchall()
            verified = connection.execute("SELECT 1 FROM messages WHERE body='synthetic room admin verified'").fetchone()
        assert actions == [('room_grant:finance',), ('room_revoke:finance',)] and verified
    finally:
        server.terminate()
        server.wait(timeout=5)
