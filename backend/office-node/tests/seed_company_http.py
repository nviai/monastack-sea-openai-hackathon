"""Seeded login, password preservation and opt-out, using disposable databases."""
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

root = Path(__file__).resolve().parents[3]
binary = root / 'backend/office-node/target/debug/monastack-office-node'
seed = json.loads((root/'data/seed/nviai/seed.v1.json').read_text())
password = 'Nviai#123'
with tempfile.TemporaryDirectory(prefix='monastack-seed-') as directory:
    db = Path(directory)/'office.sqlite3'
    env_file = Path(directory)/'.env'
    env_file.write_text('')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env = {**os.environ, 'MONASTACK_ENV_FILE': str(env_file), 'MONASTACK_DB': str(db),
           'MONASTACK_NODE_PORT': str(port), 'MONASTACK_REALTIME': 'off'}
    env.pop('MONASTACK_SEED_COMPANY', None)  # Verify default startup behavior.
    node = None
    def call(path, body=None, token=None):
        req = urllib.request.Request(f'http://127.0.0.1:{port}/v1/{path}',
            data=None if body is None else json.dumps(body).encode(),
            headers={'Content-Type': 'application/json', **({'Authorization': 'Bearer '+token} if token else {})})
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                raw = response.read()
                return response.status, json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            return error.code, error.read().decode()
    def start():
        global node
        node = subprocess.Popen([str(binary)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(400):
            if node.poll() is not None:
                raise RuntimeError('node failed')
            try:
                return call('workspace')
            except OSError:
                time.sleep(.05)
        raise RuntimeError('node startup timeout')
    def stop():
        node.terminate()
        node.wait(timeout=5)
    def login(username, secret=password):
        return call('auth/login', {'username': username, 'password': secret, 'device': 'Seed test', 'platform': 'test'})
    try:
        _, state = start()
        assert state['initialized'] and state['role'] == 'master'
        assert state['workspace']['name'] == seed['workspace']['name']
        sessions = {}
        for person in seed['actors']:
            if person['kind'] != 'human' or person['id'] not in ('le-pha', 'hua-hao', 'le-triet'):
                continue
            status, session = login(person.get('username', person['id']))
            assert status == 200, (person['id'], status)
            assert session['actor'] == person['id']
            assert session['admin'] == (person['role'] in ('org-admin', 'ceo', 'cto'))
            assert call('me', token=session['access_token'])[0] == 200
            sessions[person['id']] = session
        assert call('agents/appearances')[0] == 401
        status, appearances = call('agents/appearances', token=sessions['le-pha']['access_token'])
        assert status == 200 and len(appearances) == 6
        assert {a['id'] for a in appearances} == {a['id'] for a in seed['actors'] if a['kind'] == 'agent'}
        assert all(set(a) == {'id', 'name', 'gender', 'voice'} for a in appearances)
        assert all(a['gender'] in ('female', 'male') for a in appearances)
        for actor in ['le-pha', 'hua-hao']:
            status, settings = call('agent-configuration', token=sessions[actor]['access_token'])
            assert status == 200 and settings['can_manage']
            assert len(settings['agents']) == 6
            assert all(a['version'] >= 1 and a['config']['gender'] in ('male', 'female') for a in settings['agents'])
        with sqlite3.connect(db) as connection:
            hashes = dict(connection.execute('SELECT actor,password_hash FROM accounts WHERE disabled=0'))
        assert len(hashes) == 3 and len(set(hashes.values())) == 3
        assert all(value.startswith('$argon2id$') and password not in value for value in hashes.values())
        assert login('mona')[0] == 401
        for username in ('an','thao','hung','tuan','linh','mai','duc','van'):
            assert login(username)[0] in (401,403)
        assert len(call('admin/people', token=sessions['le-pha']['access_token'])[1]['people']) == 3
        changed = 'A changed password for testing'
        assert call('auth/password', {'current': password, 'new': changed}, sessions['le-triet']['access_token'])[0] == 204
        stop()
        # Simulate an older seeded database and verify the login-name migration.
        with sqlite3.connect(db) as connection:
            for actor, old in [('le-pha', 'le-pha'), ('hua-hao', 'hao-hua'), ('le-triet', 'le-triet')]:
                connection.execute('UPDATE accounts SET username=? WHERE actor=?', (old, actor))
            connection.execute("DELETE FROM metadata WHERE key='seed-login-names-v2'")
        start()
        assert login('pha.le')[0] == 200
        assert login('hao.hua')[0] == 200
        assert login('le-pha')[0] == 401
        assert login('hao-hua')[0] == 401
        assert login('le-triet')[0] == 401
        assert login('triet.le', changed)[0] == 200
        assert login('triet.le')[0] == 401
        with sqlite3.connect(db) as connection:
            assert connection.execute("SELECT password_hash FROM accounts WHERE actor='an'").fetchone()[0] is None
        stop()
        # A fresh member candidate/manual setup keeps the original setup flow.
        env['MONASTACK_DB'] = str(Path(directory)/'manual.sqlite3')
        env['MONASTACK_SEED_COMPANY'] = '0'
        _, state = start()
        assert not state['initialized']
        stop()
        # Already-joined member metadata is never promoted or password-seeded.
        member_db = Path(directory)/'member.sqlite3'
        subprocess.run([str(binary), 'setup-code'], env={**env, 'MONASTACK_DB': str(member_db)}, check=True, capture_output=True)
        with sqlite3.connect(member_db) as connection:
            connection.execute("INSERT INTO metadata VALUES ('identity-role','member'), ('workspace-id','synthetic-workspace'), ('workspace-name','Synthetic Member')")
        env['MONASTACK_DB'] = str(member_db)
        env['MONASTACK_SEED_COMPANY'] = '1'
        _, state = start()
        assert state['role'] == 'member'
        with sqlite3.connect(member_db) as connection:
            assert connection.execute('SELECT COUNT(*) FROM accounts').fetchone()[0] == 0
        print('Seed company: 3 real logins, admin roles, salted hashes, restart/password preservation, opt-out and member checks passed.')
    finally:
        if node is not None and node.poll() is None:
            stop()
