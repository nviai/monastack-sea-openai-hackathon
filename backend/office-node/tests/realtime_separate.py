"""Run the authority and the realtime service as separate processes.

Checks ticket-based presence, room isolation, epoch revocation observed over
HTTP, fail-closed behaviour while the authority is unreachable, and recovery.
"""
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

from realtime_client import Realtime, ticket, _call

root = Path(__file__).resolve().parents[3]
node = root / 'backend/office-node/target/debug/monastack-office-node'


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def wait_for(url, expect_http_error=True):
    for _ in range(100):
        try:
            urllib.request.urlopen(url, timeout=.2)
            return
        except urllib.error.HTTPError:
            if expect_http_error:
                return
            time.sleep(.05)
        except OSError:
            time.sleep(.05)
    raise RuntimeError(f'{url} did not start')


def eventually(check, seconds, label):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return time.monotonic()
        time.sleep(.1)
    raise AssertionError(label)


with tempfile.TemporaryDirectory(prefix='monastack-realtime-separate-') as directory:
    tmp = Path(directory)
    key_file = tmp / 'realtime.key'
    key_file.write_text(secrets.token_hex(32))
    key_file.chmod(0o600)
    authority_port, realtime_port = free_port(), free_port()
    env = {**os.environ, 'MONASTACK_DB': str(tmp / 'office.sqlite3'),
           'MONASTACK_NODE_PORT': str(authority_port),
           'MONASTACK_REALTIME': 'external',
           'MONASTACK_REALTIME_PORT': str(realtime_port),
           'MONASTACK_REALTIME_KEY_FILE': str(key_file)}
    tokens = {actor: secrets.token_hex(32) for actor in ('an', 'van')}
    for actor, token in tokens.items():
        subprocess.run([str(node), 'enroll', actor], env=env, input=token, text=True, check=True)

    def start_authority():
        process = subprocess.Popen([str(node)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(f'http://127.0.0.1:{authority_port}/v1/me')
        return process

    authority = start_authority()
    realtime = subprocess.Popen([str(node), 'realtime'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        health = f'http://127.0.0.1:{realtime_port}/v1/realtime/health'
        wait_for(health)
        eventually(lambda: _call(health)[0] == 204, 5, 'realtime observes authority epoch')
        an, van = Realtime(authority_port, tokens['an']), Realtime(authority_port, tokens['van'])
        _, url = ticket(authority_port, tokens['an'])
        assert url == f'http://127.0.0.1:{realtime_port}'
        sessions = {who: secrets.token_hex(16) for who in ('an', 'van')}
        assert an.publish(sessions['an'], 'lobby', 14, 13, 1) == 204
        assert van.publish(sessions['van'], 'finance', 25, 23, 1) == 204
        assert an.publish(sessions['an'], 'finance', 25, 23, 2) == 403
        # Private-room presence is only visible to members.
        assert {p['actor'] for p in an.presence()} == {'an'}
        assert {p['actor'] for p in van.presence()} == {'an', 'van'}
        # A ticket signed with another key is rejected.
        forged = ticket(authority_port, tokens['an'])[0].split('.')[0] + '.' + '00' * 32
        assert an.request('GET', 'presence', ticket_override=forged)[0] == 401
        # Revocation reaches the separate service through the polled epoch.
        stale, _ = ticket(authority_port, tokens['van'])
        revoked_at = time.monotonic()
        subprocess.run([str(node), 'room', 'revoke', 'finance', 'van'], env=env, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        seen = eventually(lambda: van.request('GET', 'presence', ticket_override=stale)[0] == 401,
                          5, 'stale ticket rejected after revocation')
        assert all(p['room'] != 'finance' for p in van.presence())
        assert van.publish(sessions['van'], 'finance', 25, 23, 2) == 403
        print(f'Separate realtime observed revocation after {seen - revoked_at:.1f}s')
        # Without the authority the realtime service stops serving (fail closed).
        valid, _ = ticket(authority_port, tokens['an'])
        authority.terminate()
        authority.wait(timeout=5)
        stopped_at = time.monotonic()
        closed = eventually(
            lambda: _call(f'http://127.0.0.1:{realtime_port}/v1/presence', 'GET',
                          {'Authorization': 'Ticket ' + valid})[0] == 503,
            20, 'realtime fails closed without the authority')
        print(f'Realtime failed closed {closed - stopped_at:.1f}s after the authority stopped')
        authority = start_authority()
        eventually(lambda: _call(health)[0] == 204, 5, 'realtime recovers')
        assert an.publish(sessions['an'], 'lobby', 14, 13, 3) == 204
        print('Separate authority and realtime processes: tickets, isolation, epoch revocation, fail-closed and recovery passed')
    finally:
        realtime.terminate()
        realtime.wait(timeout=5)
        authority.terminate()
        authority.wait(timeout=5)
