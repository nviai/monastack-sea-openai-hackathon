"""Drive company setup and sign-in in the macOS app against a fresh node.

The node starts unconfigured and prints its setup code; the app sets up the
company, invites someone, redeems the invitation, signs in with a password
and restores its session from the macOS login keychain after a relaunch.
Afterwards the node must show the signed-out sessions as revoked.
"""
import os
from pathlib import Path
import re
import socket
import sqlite3
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[3]
node = root / 'backend/office-node/target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack-sign-in-app-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    db = Path(directory) / 'office.sqlite3'
    log = Path(directory) / 'node.log'
    env = {**os.environ, 'MONASTACK_SEED_COMPANY': '0', 'MONASTACK_DB': str(db), 'MONASTACK_NODE_PORT': str(port),
           'MONASTACK_TEST_ISOLATED_OUTBOX': '1'}
    env.pop('MONASTACK_SIGN_IN', None)
    server = subprocess.Popen([str(node)], env=env, stdout=subprocess.DEVNULL, stderr=log.open('w'))
    try:
        code = None
        for _ in range(200):
            match = re.search(r'Setup code: ([A-Z0-9-]{19})', log.read_text())
            if match:
                code = match.group(1)
                break
            if server.poll() is not None:
                raise RuntimeError(log.read_text())
            time.sleep(.05)
        assert code, 'node printed a setup code'
        result = subprocess.run(
            ['flutter', 'test', 'integration_test/sign_in_test.dart', '-d', 'macos'],
            cwd=root / 'app', env={**env, 'MONASTACK_TEST_SETUP_CODE': code},
            capture_output=True, text=True, timeout=600)
        output = result.stdout + result.stderr
        if result.returncode != 0:
            print(output[-6000:])
            raise SystemExit('sign-in app test failed')
        print('\n'.join(l for l in output.splitlines() if l.startswith('sign-in app:')))
        with sqlite3.connect(db) as conn:
            role = conn.execute("SELECT value FROM metadata WHERE key='identity-role'").fetchone()
            accounts = dict(conn.execute('SELECT username, actor FROM accounts').fetchall())
            live = conn.execute('SELECT COUNT(*) FROM sessions WHERE revoked=0').fetchone()[0]
            reasons = [r for (r,) in conn.execute('SELECT revoked_reason FROM sessions WHERE revoked=1')]
        assert role == ('master',)
        assert accounts['an.admin'] == 'an' and 'invited' in accounts
        assert live == 0, f'{live} sessions still live after sign-out'
        assert reasons.count('signed_out') == 3, reasons
        print('macOS app sign-in: company setup, invitation, password sign-in, keychain restore and sign-out passed')
    finally:
        server.terminate()
        server.wait(timeout=5)
