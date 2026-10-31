"""Test restricted-room grant and revocation with an isolated macOS app."""
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
from realtime_client import Realtime

# The app signs in with the enrolled device token, not a password (ADR 0008).
os.environ.setdefault('MONASTACK_SIGN_IN', 'token')

root = Path(__file__).resolve().parents[3]
node = root / 'backend/office-node/target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack-room-membership-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    token = secrets.token_hex(32)
    env = {**os.environ, 'MONASTACK_DB': str(Path(directory) / 'office.sqlite3'),
           'MONASTACK_NODE_PORT': str(port), 'MONASTACK_TEST_TOKEN': token,
           'MONASTACK_TEST_ISOLATED_OUTBOX': '1'}
    subprocess.run([str(node), 'enroll', 'an'], env=env, input=token, text=True, check=True)
    server = subprocess.Popen([str(node)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    stop = threading.Event()
    errors = []
    watcher = None
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
        def change_membership():
            try:
                granted = False
                while not stop.wait(.1):
                    if not granted:
                        with sqlite3.connect(env['MONASTACK_DB'], timeout=2) as connection:
                            found = connection.execute("SELECT 1 FROM messages WHERE body='synthetic grant requested'").fetchone()
                    else:
                        found = any(p['actor'] == 'an' and p['room'] == 'finance' and (p['x'], p['y']) == (25, 23)
                                    for p in Realtime(port, env['MONASTACK_TEST_TOKEN']).presence())
                    if found:
                        action = 'revoke' if granted else 'grant'
                        subprocess.run([str(node), 'room', action, 'finance', 'an'], env=env, check=True)
                        if granted:
                            return
                        granted = True
            except Exception as error:
                errors.append(error)
        watcher = threading.Thread(target=change_membership, daemon=True)
        watcher.start()
        test = subprocess.Popen(['flutter', 'test', 'integration_test/room_membership_test.dart', '-d', 'macos'],
                                cwd=root / 'app', env=env, start_new_session=True)
        try:
            code = test.wait(timeout=150)
        except subprocess.TimeoutExpired:
            os.killpg(test.pid, signal.SIGKILL)
            test.wait(timeout=5)
            raise
        if code:
            raise subprocess.CalledProcessError(code, test.args)
        if errors:
            raise RuntimeError('membership watcher failed') from errors[0]
        with sqlite3.connect(env['MONASTACK_DB']) as connection:
            actions = connection.execute("SELECT action FROM security_audit WHERE subject='an' AND action IN ('room_grant:finance','room_revoke:finance') ORDER BY seq").fetchall()
            assert actions == [('room_grant:finance',), ('room_revoke:finance',)]
            assert connection.execute("SELECT 1 FROM messages WHERE body='synthetic membership verified'").fetchone()
    finally:
        stop.set()
        if watcher is not None:
            watcher.join(timeout=5)
        server.terminate()
        server.wait(timeout=5)
