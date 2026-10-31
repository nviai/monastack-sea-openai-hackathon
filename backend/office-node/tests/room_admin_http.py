"""Exercise authenticated, audited room administration in a disposable workspace."""
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
with tempfile.TemporaryDirectory(prefix='monastack-room-admin-') as directory:
    db = Path(directory) / 'office.sqlite3'
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    tokens = {actor: secrets.token_hex(32) for actor in ('an', 'van')}
    env = {**os.environ, 'MONASTACK_DB': str(db), 'MONASTACK_NODE_PORT': str(port)}
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
        assert request('an', 'GET', 'room-admin/capabilities')[1]['can_manage'] is True
        assert request('van', 'GET', 'room-admin/capabilities')[1]['can_manage'] is False
        assert request('van', 'GET', 'room-admin/finance/members')[0] == 403
        assert request('an', 'GET', 'room-admin/lobby/members')[0] == 404
        assert request('an', 'GET', 'messages/room%3Afinance')[0] == 403
        assert request('an', 'GET', 'room-admin/finance/members')[1]['version'] == 0
        command = {'actor': 'an', 'action': 'grant', 'op': secrets.token_hex(16), 'expected_version': 0}
        assert request('van', 'POST', 'room-admin/finance/members', command)[0] == 403
        assert request('an', 'POST', 'room-admin/finance/members', command)[0] == 200
        assert request('an', 'POST', 'room-admin/finance/members', command)[0] == 200
        assert request('an', 'POST', 'room-admin/finance/members', dict(command, action='revoke'))[0] == 409
        assert request('an', 'POST', 'room-admin/finance/members', dict(command, op=secrets.token_hex(16), expected_version=1))[0] == 409
        assert request('an', 'POST', 'room-admin/finance/members', {'actor':'mona','action':'grant','op':secrets.token_hex(16),'expected_version':1})[0] == 404
        assert request('an', 'GET', 'messages/room%3Afinance')[0] == 200
        subprocess.run([str(node), 'room', 'revoke', 'finance', 'an'], env=env, check=True)
        assert request('an', 'GET', 'messages/room%3Afinance')[0] == 403
        assert request('an', 'GET', 'room-admin/finance/members')[1]['version'] == 2
        assert request('an', 'POST', 'room-admin/finance/members', dict(command, op=secrets.token_hex(16)))[0] == 409
        history = request('an', 'GET', 'room-admin/finance/history')[1]
        assert [(e['actor'],e['subject'],e['action']) for e in history[:2]] == [('local-operator','an','revoke'),('an','an','grant')]
        with sqlite3.connect(db) as connection:
            connection.execute("DELETE FROM actor_roles WHERE actor='an' AND role='org-admin'")
        assert request('an', 'POST', 'room-admin/finance/members', command)[0] == 403
        assert request('an', 'GET', 'room-admin/finance/history')[0] == 403
        print('Room administration: authority, explicit grant, replay, audit and revocation passed')
    finally:
        server.terminate()
        server.wait(timeout=5)
