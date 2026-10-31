"""Verify one macOS client removes an abruptly killed synthetic peer."""
import os
from pathlib import Path
import secrets
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import json

# The app signs in with the enrolled device token, not a password (ADR 0008).
os.environ.setdefault('MONASTACK_SIGN_IN', 'token')

root = Path(__file__).resolve().parents[3]
node = root / 'backend/office-node/target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack-presence-crash-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    tokens = {actor: secrets.token_hex(32) for actor in ('an', 'van')}
    env = {**os.environ, 'MONASTACK_DB': str(Path(directory) / 'office.sqlite3'),
           'MONASTACK_NODE_PORT': str(port), 'MONASTACK_TEST_TOKEN': tokens['an'],
           'MONASTACK_TEST_ISOLATED_OUTBOX': '1'}
    for actor, token in tokens.items():
        subprocess.run([str(node), 'enroll', actor], env=env, input=token, text=True, check=True)
    server = subprocess.Popen([str(node)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    peer = None
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
        # Credentials are passed over stdin and never included in the process command line.
        peer_code = r'''import json,sys,time,urllib.request
data=json.load(sys.stdin)
seq=0
while True:
 seq+=1
 req=urllib.request.Request('http://127.0.0.1:'+str(data['port'])+'/v1/realtime/ticket',data=b'{}',method='POST',headers={'Authorization':'Bearer '+data['token'],'Content-Type':'application/json'})
 with urllib.request.urlopen(req,timeout=3) as response: issued=json.load(response)
 body=json.dumps({'session':data['session'],'room':'lobby','x':13,'y':12,'seq':seq}).encode()
 req=urllib.request.Request(issued['realtime_url']+'/v1/presence',data=body,method='POST',headers={'Authorization':'Ticket '+issued['ticket'],'Content-Type':'application/json'})
 with urllib.request.urlopen(req,timeout=3) as response: response.read()
 time.sleep(3)
'''
        peer = subprocess.Popen([sys.executable, '-c', peer_code], stdin=subprocess.PIPE,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
        peer.stdin.write(json.dumps({'port': port, 'token': tokens['van'], 'session': secrets.token_hex(16)}))
        peer.stdin.close()
        def kill_on_marker():
            try:
                while not stop.wait(.1):
                    if peer.poll() is not None:
                        raise RuntimeError('synthetic peer exited before crash marker')
                    with sqlite3.connect(env['MONASTACK_DB'], timeout=2) as connection:
                        found = connection.execute("SELECT 1 FROM messages WHERE body='synthetic presence crash marker'").fetchone()
                    if found:
                        peer.kill()
                        peer.wait(timeout=5)
                        return
            except Exception as error:
                errors.append(error)
        watcher = threading.Thread(target=kill_on_marker, daemon=True)
        watcher.start()
        test = subprocess.Popen(['flutter', 'test', 'integration_test/presence_crash_test.dart', '-d', 'macos'],
                                cwd=root / 'app', env=env, start_new_session=True)
        try:
            code = test.wait(timeout=240)
        except subprocess.TimeoutExpired:
            os.killpg(test.pid, signal.SIGKILL)
            test.wait(timeout=5)
            raise
        if code:
            raise subprocess.CalledProcessError(code, test.args)
        if errors or peer.poll() != -signal.SIGKILL:
            raise RuntimeError('synthetic peer crash was not observed') from (errors[0] if errors else None)
        with sqlite3.connect(env['MONASTACK_DB']) as connection:
            if not connection.execute("SELECT 1 FROM messages WHERE body='synthetic presence expiry verified'").fetchone():
                raise RuntimeError('client did not verify presence expiry')
    finally:
        stop.set()
        if watcher is not None:
            watcher.join(timeout=5)
        if peer is not None and peer.poll() is None:
            peer.kill()
            peer.wait(timeout=5)
        server.terminate()
        server.wait(timeout=5)
