"""Start an isolated loopback node and exercise a built macOS app client."""
import os
import json
from pathlib import Path
import secrets
import socket
import sqlite3
import threading
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

root = Path(__file__).resolve().parents[3]
binary = root / 'backend/office-node/target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack-app-test-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env = {**os.environ, 'MONASTACK_DB': str(Path(directory) / 'office.sqlite3')}
    env['MONASTACK_NODE_PORT'] = str(port)
    env['MONASTACK_TEST_ISOLATED_OUTBOX'] = '1'
    for actor in ('an', 'van'):
        token = secrets.token_hex(32)
        env['MONASTACK_TEST_' + actor.upper()] = token
        subprocess.run([str(binary), 'enroll', actor], env=env, input=token, text=True, check=True)
    node = subprocess.Popen([str(binary)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if node.poll() is not None:
                raise RuntimeError('node failed to start; the selected port may be in use')
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{port}/v1/me', timeout=.2)
            except urllib.error.HTTPError:
                break
            except OSError:
                time.sleep(.05)
        else:
            raise RuntimeError('node did not start')
        stopped = threading.Event()
        def revoke_when_in_finance():
            while not stopped.wait(.1):
                with sqlite3.connect(env['MONASTACK_DB'], timeout=2) as conn:
                    found = conn.execute("SELECT 1 FROM presence WHERE actor='van' AND room='finance' AND x=2 AND y=14").fetchone()
                    if found:
                        conn.execute("DELETE FROM room_members WHERE room='finance' AND actor='van'")
                        return
        watcher = threading.Thread(target=revoke_when_in_finance, daemon=True)
        if env.get('MONASTACK_TEST_REVOCATION') == '1':
            watcher.start()
        try:
            if env.get('MONASTACK_TEST_ONLY_LEAVE') != '1':
                subprocess.run(['flutter', 'test', 'integration_test/node_test.dart', '-d', 'macos'], cwd=root / 'app', env=env, check=True, timeout=90)
                subprocess.run(['flutter', 'test', 'integration_test/outbox_test.dart', '-d', 'macos'], cwd=root / 'app', env=env, check=True, timeout=90)
            # Test-only HR authority: no HR personnel are added to the seed.
            subprocess.run([str(binary), 'role', 'grant', 'hr', 'van'], env=env, check=True)
            leave_id = secrets.token_hex(16)
            def post(actor, path, body):
                req = urllib.request.Request(f'http://127.0.0.1:{port}/v1/{path}',
                    data=json.dumps(body).encode(), method='POST',
                    headers={'Authorization': 'Bearer '+env['MONASTACK_TEST_'+actor.upper()], 'Content-Type': 'application/json'})
                with urllib.request.urlopen(req, timeout=3) as response:
                    return response.status
            assert post('an', 'leave', {'id':leave_id, 'start_date':'2026-11-02', 'end_date':'2026-11-03', 'reason':'Synthetic cancellation test', 'op':secrets.token_hex(16)}) == 201
            assert post('van', f'leave/{leave_id}/decision', {'action':'approve', 'expected_version':1, 'op':secrets.token_hex(16)}) == 200
            subprocess.run(['flutter', 'test', 'integration_test/leave_cancellation_test.dart', '-d', 'macos'], cwd=root / 'app', env=env, check=True, timeout=90)
            with sqlite3.connect(env['MONASTACK_DB']) as conn:
                assert conn.execute('SELECT state,version FROM leave_requests WHERE id=?', (leave_id,)).fetchone() == ('cancellation_pending', 3)
            assert post('van', f'leave/{leave_id}/decision', {'action':'cancel_approve', 'expected_version':3, 'op':secrets.token_hex(16)}) == 200
            with sqlite3.connect(env['MONASTACK_DB']) as conn:
                assert conn.execute('SELECT state FROM leave_requests WHERE id=?', (leave_id,)).fetchone()[0] == 'cancelled'
        finally:
            stopped.set()
            if watcher.is_alive():
                watcher.join(timeout=3)
    finally:
        node.terminate()
        node.wait(timeout=5)
