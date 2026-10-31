"""Exercise the calendar UI against an isolated local node and synthetic leave."""
import json
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

root = Path(__file__).resolve().parents[3]
node = root / 'backend/office-node/target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack-leave-calendar-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    tokens = {actor: secrets.token_hex(32) for actor in ('an', 'van')}
    env = {**os.environ, 'MONASTACK_DB': str(Path(directory) / 'office.sqlite3'),
           'MONASTACK_NODE_PORT': str(port), 'MONASTACK_TEST_TOKEN': tokens['an']}
    for actor, token in tokens.items():
        subprocess.run([str(node), 'enroll', actor], env=env, input=token, text=True, check=True)
    subprocess.run([str(node), 'role', 'grant', 'hr', 'an'], env=env, check=True)
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
        def post(actor, path, body):
            req = urllib.request.Request(f'http://127.0.0.1:{port}/v1/{path}', method='POST',
                data=json.dumps(body).encode(), headers={'Authorization': 'Bearer ' + tokens[actor],
                                                        'Content-Type': 'application/json'})
            with urllib.request.urlopen(req, timeout=3) as response:
                return response.status
        leave_id = secrets.token_hex(16)
        assert post('van', 'leave', {'id': leave_id, 'start_date': '2026-10-31',
            'end_date': '2026-11-02', 'reason': 'Synthetic private reason',
            'op': secrets.token_hex(16)}) == 201
        assert post('an', f'leave/{leave_id}/decision', {'action': 'approve',
            'expected_version': 1, 'op': secrets.token_hex(16)}) == 200
        subprocess.run(['flutter', 'test', 'integration_test/leave_calendar_test.dart', '-d', 'macos'],
                       cwd=root / 'app', env=env, check=True, timeout=90)
        # Only the disposable fixture is populated directly for the size boundary.
        with sqlite3.connect(env['MONASTACK_DB']) as connection:
            connection.executemany(
                'INSERT INTO leave_requests VALUES (?,?,?,?,?,?,?,?)',
                [(f'calendar-synthetic-{index:04d}', 'van', '2026-11-01', '2026-11-01',
                  'Synthetic', 'approved', 1, 1) for index in range(501)],
            )
        def read_calendar():
            req = urllib.request.Request(f'http://127.0.0.1:{port}/v1/leave/calendar?month=2026-11',
                                         headers={'Authorization': 'Bearer ' + tokens['an']})
            with urllib.request.urlopen(req, timeout=3) as response:
                return json.load(response)
        result = read_calendar()
        assert result['truncated'] is True and len(result['items']) == 500
        subprocess.run([str(node), 'role', 'revoke', 'hr', 'an'], env=env, check=True)
        result = read_calendar()
        assert result['items'] == [] and result['truncated'] is False
    finally:
        server.terminate()
        server.wait(timeout=5)
