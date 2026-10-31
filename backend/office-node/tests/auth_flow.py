"""Workspace identity end to end (ADR 0008), with temporary databases.

A fresh node is set up as the identity master through its setup code. The
test covers sign-in, lockout, refresh rotation and reuse detection,
invitations, resets, device sessions, disabling, password changes, realtime
tickets and the legacy device token. A second node then joins as a member,
forwards sign-in to the master, checks access tokens locally and follows
revocations through directory sync, also while the master is down.
"""
import json
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

binary = Path(__file__).resolve().parents[1] / 'target/debug/monastack-office-node'
PASSWORD = 'correct horse battery'


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def call(port, method, path, body=None, token=None):
    request = urllib.request.Request(
        f'http://127.0.0.1:{port}{path}', method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={'Content-Type': 'application/json',
                 **({'Authorization': f'Bearer {token}'} if token else {})})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            text = response.read().decode()
            return response.status, (json.loads(text) if text else None)
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def eventually(check, seconds, label):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return time.monotonic()
        time.sleep(.2)
    raise AssertionError(label)


class Node:
    def __init__(self, directory, name):
        self.db = Path(directory) / f'{name}.sqlite3'
        self.log = Path(directory) / f'{name}.log'
        self.port = free_port()
        self.env = {**os.environ, 'MONASTACK_DB': str(self.db),
                    'MONASTACK_NODE_PORT': str(self.port), 'MONASTACK_REALTIME': 'embedded'}
        self.process = None

    def cli(self, *args, stdin=''):
        return subprocess.run([str(binary), *args], env=self.env, input=stdin,
                              text=True, capture_output=True)

    def start(self):
        self.process = subprocess.Popen([str(binary)], env=self.env, stdout=subprocess.DEVNULL,
                                        stderr=self.log.open('w'))
        for _ in range(200):
            if self.process.poll() is not None:
                raise RuntimeError(f'node failed: {self.log.read_text()}')
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{self.port}/v1/workspace', timeout=.2)
                return
            except OSError:
                time.sleep(.05)
        raise RuntimeError('node did not start')

    def stop(self):
        if self.process is not None:
            self.process.terminate()
            self.process.wait(timeout=5)
            self.process = None

    def __call__(self, method, path, body=None, token=None):
        return call(self.port, method, path, body, token)


def device(name):
    return {'device': name, 'platform': 'test'}


with tempfile.TemporaryDirectory(prefix='monastack-auth-') as directory:
    master = Node(directory, 'master')
    member = Node(directory, 'member')
    try:
        # ---------------------------------------------------------------- setup
        master.start()
        status, state = master('GET', '/v1/workspace')
        assert status == 200 and state['initialized'] is False and state['role'] == 'unconfigured'
        assert any(p['id'] == 'an' for p in state['people'])
        printed = re.search(r'Setup code: ([A-Z0-9-]{19})', master.log.read_text())
        assert printed, 'setup code printed at startup'
        setup = {'company': 'Synthetic Co', 'actor': 'an', 'username': 'an.admin',
                 'password': PASSWORD, **device('admin mac')}
        assert master('POST', '/v1/setup', {**setup, 'code': 'AAAA-AAAA-AAAA-AAAA'})[0] == 403
        assert master('POST', '/v1/setup', {**setup, 'code': printed.group(1), 'password': 'short'})[0] == 400
        # The CLI replaces the printed code; the old one stops working.
        fresh = master.cli('setup-code')
        assert fresh.returncode == 0
        code = fresh.stdout.strip()
        assert master('POST', '/v1/setup', {**setup, 'code': printed.group(1)})[0] == 403
        status, admin = master('POST', '/v1/setup', {**setup, 'code': code.lower().replace('-', ' ')})
        assert status == 200, admin
        assert admin['actor'] == 'an' and admin['admin'] and admin['workspace']['name'] == 'Synthetic Co'
        assert master('POST', '/v1/setup', {**setup, 'code': code})[0] == 409
        assert master.cli('setup-code').returncode != 0
        status, state = master('GET', '/v1/workspace')
        assert state['initialized'] and state['role'] == 'master' and 'people' not in state
        status, me = master('GET', '/v1/me', token=admin['access_token'])
        assert status == 200 and me['actor'] == 'an' and me['workspace_name'] == 'Synthetic Co'
        assert master('GET', '/v1/rooms', token=admin['access_token'])[0] == 200
        print('Setup: setup code, single setup, first admin signed in')

        # -------------------------------------------------------------- sign-in
        assert master('POST', '/v1/auth/login', {'username': 'an.admin', 'password': 'wrong password!', **device('x')})[0] == 401
        assert master('POST', '/v1/auth/login', {'username': 'nobody', 'password': PASSWORD, **device('x')})[0] == 401
        status, second = master('POST', '/v1/auth/login', {'username': 'AN.ADMIN', 'password': PASSWORD, **device('laptop')})
        assert status == 200 and second['session'] != admin['session']
        status, sessions = master('GET', '/v1/auth/sessions', token=second['access_token'])
        assert status == 200 and {s['device'] for s in sessions} == {'admin mac', 'laptop'}
        assert [s['current'] for s in sessions if s['device'] == 'laptop'] == [True]

        # Refresh rotates; replaying an old refresh token ends the session.
        status, rotated = master('POST', '/v1/auth/refresh', {'refresh_token': second['refresh_token']})
        assert status == 200 and rotated['refresh_token'] != second['refresh_token']
        assert master('GET', '/v1/me', token=rotated['access_token'])[0] == 200
        assert master('POST', '/v1/auth/refresh', {'refresh_token': second['refresh_token']})[0] == 401
        assert master('POST', '/v1/auth/refresh', {'refresh_token': rotated['refresh_token']})[0] == 401, 'reuse revokes'
        assert master('GET', '/v1/me', token=rotated['access_token'])[0] == 401
        assert master('GET', '/v1/me', token=admin['access_token'])[0] == 200, 'other sessions unaffected'
        # Tampered and foreign tokens.
        forged = admin['access_token'][:-4] + ('AAAA' if not admin['access_token'].endswith('AAAA') else 'BBBB')
        assert master('GET', '/v1/me', token=forged)[0] == 401
        print('Sign-in: case-insensitive username, generic failures, rotation and reuse detection')

        # ----------------------------------------------------------- invitations
        status, invite = master('POST', '/v1/admin/invites', {'actor': 'van'}, token=admin['access_token'])
        assert status == 200 and invite['purpose'] == 'invite'
        status, van = master('POST', '/v1/auth/invite', {'code': invite['code'], 'username': 'van', 'password': PASSWORD, **device('van mac')})
        assert status == 200 and van['actor'] == 'van' and not van['admin']
        assert master('POST', '/v1/auth/invite', {'code': invite['code'], 'username': 'van2', 'password': PASSWORD, **device('x')})[0] == 403, 'single use'
        assert master('POST', '/v1/admin/invites', {'actor': 'mai'}, token=van['access_token'])[0] == 403, 'admins only'
        assert master('GET', '/v1/admin/people', token=van['access_token'])[0] == 403
        status, newcomer_invite = master('POST', '/v1/admin/invites', {'name': 'Synthetic Newcomer'}, token=admin['access_token'])
        assert status == 200
        status, newcomer = master('POST', '/v1/auth/invite', {'code': newcomer_invite['code'], 'username': 'van', 'password': PASSWORD, **device('x')})
        assert status == 409, 'username taken'
        status, newcomer = master('POST', '/v1/auth/invite', {'code': newcomer_invite['code'], 'username': 'newcomer', 'password': PASSWORD, **device('new')})
        assert status == 200 and newcomer['name'] == 'Synthetic Newcomer'
        status, people = master('GET', '/v1/admin/people', token=admin['access_token'])
        by_id = {p['id']: p for p in people['people']}
        assert by_id['van']['username'] == 'van' and by_id['an']['admin'] and by_id[newcomer['actor']]['sessions'] == 1
        print('Invitations: seeded and new people, single use, admin only')

        # --------------------------------------------------------------- lockout
        for _ in range(5):
            assert master('POST', '/v1/auth/login', {'username': 'van', 'password': 'wrong password!', **device('x')})[0] == 401
        assert master('POST', '/v1/auth/login', {'username': 'van', 'password': PASSWORD, **device('x')})[0] == 429
        assert master('GET', '/v1/me', token=van['access_token'])[0] == 200, 'lockout does not end sessions'
        # A reset code from the local operator unlocks, sets a new password
        # and ends every session.
        reset = master.cli('account-code', 'van')
        assert reset.returncode == 0 and 'reset' in reset.stderr
        status, van = master('POST', '/v1/auth/invite', {'code': reset.stdout.strip(), 'password': 'another long password', **device('van mac')})
        assert status == 200 and van['username'] == 'van'
        assert master('POST', '/v1/auth/login', {'username': 'van', 'password': 'another long password', **device('x')})[0] == 200
        print('Lockout after 5 failures; operator reset code restores access')

        # ------------------------------------------------- devices and accounts
        status, other = master('POST', '/v1/auth/login', {'username': 'van', 'password': 'another long password', **device('van phone')})
        assert master('POST', f"/v1/auth/sessions/{other['session']}/revoke", token=newcomer['access_token'])[0] == 403
        assert master('POST', f"/v1/auth/sessions/{other['session']}/revoke", token=van['access_token'])[0] == 204
        assert master('GET', '/v1/me', token=other['access_token'])[0] == 401
        assert master('POST', '/v1/auth/refresh', {'refresh_token': other['refresh_token']})[0] == 401
        # Password change keeps this session and ends the others.
        status, extra = master('POST', '/v1/auth/login', {'username': 'van', 'password': 'another long password', **device('van tablet')})
        assert master('POST', '/v1/auth/password', {'current': 'wrong', 'new': 'third long password'}, token=van['access_token'])[0] == 403
        assert master('POST', '/v1/auth/password', {'current': 'another long password', 'new': 'third long password'}, token=van['access_token'])[0] == 204
        assert master('GET', '/v1/me', token=van['access_token'])[0] == 200
        assert master('GET', '/v1/me', token=extra['access_token'])[0] == 401
        # Realtime tickets follow the session.
        status, issued = master('POST', '/v1/realtime/ticket', token=van['access_token'])
        assert status == 200 and issued['ticket']
        # Disabling signs out and blocks sign-in; admins cannot disable themselves.
        assert master('POST', '/v1/admin/people/an/state', {'disabled': True}, token=admin['access_token'])[0] == 409
        assert master('POST', '/v1/admin/people/van/state', {'disabled': True}, token=admin['access_token'])[0] == 204
        assert master('GET', '/v1/me', token=van['access_token'])[0] == 401
        assert master('POST', '/v1/realtime/ticket', token=van['access_token'])[0] == 401
        assert master('POST', '/v1/auth/login', {'username': 'van', 'password': 'third long password', **device('x')})[0] == 403
        assert master('POST', '/v1/admin/people/van/state', {'disabled': False}, token=admin['access_token'])[0] == 204
        status, van = master('POST', '/v1/auth/login', {'username': 'van', 'password': 'third long password', **device('van mac')})
        assert status == 200
        # Sign-out ends the session.
        assert master('POST', '/v1/auth/logout', token=newcomer['access_token'])[0] == 204
        assert master('GET', '/v1/me', token=newcomer['access_token'])[0] == 401
        # Legacy device tokens still work for operators and tests.
        legacy = secrets.token_hex(32)
        assert master.cli('enroll', 'mai', stdin=legacy).returncode == 0
        assert master('GET', '/v1/me', token=legacy)[1]['actor'] == 'mai'
        assert master('POST', '/v1/admin/workspace', {'name': 'Renamed Co'}, token=admin['access_token'])[0] == 204
        print('Devices: revoke own/admin, password change, disable/enable, sign-out, legacy token')

        # ------------------------------------------------------------ federation
        assert member.cli('setup-code').returncode == 0  # creates and seeds the database
        status, join = master('POST', '/v1/admin/nodes', {'name': 'synthetic member'}, token=admin['access_token'])
        assert status == 200
        assert member.cli('join', f'http://127.0.0.1:{master.port}', stdin='AAAA-AAAA-AAAA-AAAA').returncode != 0
        joined = member.cli('join', f'http://127.0.0.1:{master.port}', stdin=join['code'])
        assert joined.returncode == 0, joined.stderr
        assert member.cli('join', f'http://127.0.0.1:{master.port}', stdin=join['code']).returncode != 0
        member.start()
        status, state = member('GET', '/v1/workspace')
        assert state['role'] == 'member' and state['workspace']['name'] == 'Renamed Co'
        assert 'Setup code' not in member.log.read_text()
        assert member('POST', '/v1/setup', {**setup, 'code': code})[0] == 409, 'setup forwarded to the configured master'
        # Sign-in through the member is forwarded; tokens work on both nodes.
        status, remote = member('POST', '/v1/auth/login', {'username': 'van', 'password': 'third long password', **device('member mac')})
        assert status == 200, remote
        assert member('GET', '/v1/me', token=remote['access_token'])[1]['actor'] == 'van'
        assert member('GET', '/v1/rooms', token=remote['access_token'])[0] == 200
        assert master('GET', '/v1/me', token=remote['access_token'])[0] == 200
        assert member('POST', '/v1/realtime/ticket', token=remote['access_token'])[0] == 200
        status, devices = member('GET', '/v1/auth/sessions', token=remote['access_token'])
        assert status == 200 and any(d['device'] == 'member mac' and d['current'] for d in devices)
        # A person invited on the master can work on the member after sync.
        status, late = master('POST', '/v1/admin/invites', {'name': 'Synthetic Latecomer'}, token=admin['access_token'])
        status, latecomer = member('POST', '/v1/auth/invite', {'code': late['code'], 'username': 'late', 'password': PASSWORD, **device('m')})
        assert status == 200
        eventually(lambda: member('GET', '/v1/me', token=latecomer['access_token'])[0] == 200, 10, 'new person synced')
        # Revocation at the master reaches the member within the sync period.
        assert master('POST', f"/v1/auth/sessions/{remote['session']}/revoke", token=admin['access_token'])[0] == 204
        revoked = time.monotonic()
        seen = eventually(lambda: member('GET', '/v1/me', token=remote['access_token'])[0] == 401, 10, 'member saw revocation')
        print(f'Federation: member rejected a revoked session after {seen - revoked:.1f}s')
        assert master('POST', f"/v1/admin/people/{latecomer['actor']}/state", {'disabled': True}, token=admin['access_token'])[0] == 204
        eventually(lambda: member('GET', '/v1/me', token=latecomer['access_token'])[0] == 401, 10, 'member saw disable')
        # Sign-out through the member takes effect there at once.
        status, quick = member('POST', '/v1/auth/login', {'username': 'van', 'password': 'third long password', **device('m2')})
        assert member('POST', '/v1/auth/logout', token=quick['access_token'])[0] == 204
        assert member('GET', '/v1/me', token=quick['access_token'])[0] == 401
        # Master down: existing access tokens keep working until they expire;
        # new sign-ins fail clearly.
        status, still = member('POST', '/v1/auth/login', {'username': 'van', 'password': 'third long password', **device('m3')})
        master.stop()
        assert member('GET', '/v1/me', token=still['access_token'])[0] == 200
        assert member('POST', '/v1/auth/login', {'username': 'van', 'password': 'third long password', **device('m4')})[0] == 502
        master.start()
        # Revoking the member node stops its directory sync.
        status, listed = master('GET', '/v1/admin/nodes', token=admin['access_token'])
        node_id = [n for n in listed if n['joined']][0]['id']
        assert master('POST', f'/v1/admin/nodes/{node_id}/revoke', token=admin['access_token'])[0] == 204
        eventually(lambda: 'identity sync failing' in member.log.read_text(), 15, 'member noticed revocation')
        print('Federation: forwarded sign-in, local token checks, sync of people, revocation and disable, master outage, node revocation')
        print('Workspace identity end to end passed')
    finally:
        member.stop()
        master.stop()
