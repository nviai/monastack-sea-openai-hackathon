"""Verify a queued synthetic chat survives a macOS app process restart."""
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

root = Path(__file__).resolve().parents[3]
node = root / 'backend/office-node/target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack-chat-restart-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    token = secrets.token_hex(32)
    env = {**os.environ, 'MONASTACK_DB': str(Path(directory) / 'office.sqlite3'),
           'MONASTACK_NODE_PORT': str(port), 'MONASTACK_TEST_TOKEN': token,
           'MONASTACK_TEST_ISOLATED_OUTBOX': '1', 'MONASTACK_TEST_OUTBOX_SCOPE': secrets.token_hex(16)}
    subprocess.run([str(node), 'enroll', 'an'], env=env, input=token, text=True, check=True)
    def start():
        server = subprocess.Popen([str(node)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            if server.poll() is not None:
                raise RuntimeError('node failed')
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{port}/v1/me', timeout=.2)
            except urllib.error.HTTPError:
                return server
            except OSError:
                time.sleep(.05)
        server.terminate()
        server.wait(timeout=5)
        raise RuntimeError('node did not start')
    server = start()
    stop = threading.Event()
    errors = []
    def stop_on_marker():
        try:
            while not stop.wait(.1):
                with sqlite3.connect(env['MONASTACK_DB'], timeout=2) as connection:
                    found = connection.execute("SELECT 1 FROM messages WHERE body LIKE 'synthetic outage marker %'").fetchone()
                if found:
                    if stop.wait(2):
                        return
                    server.terminate()
                    server.wait(timeout=5)
                    return
        except Exception as error:
            errors.append(error)
    watcher = threading.Thread(target=stop_on_marker, daemon=True)
    watcher.start()
    def run_app(phase):
        test = subprocess.Popen(['flutter', 'test', 'integration_test/chat_process_restart_test.dart', '-d', 'macos'],
                                cwd=root / 'app', env={**env, 'MONASTACK_TEST_PHASE': phase},
                                start_new_session=True)
        try:
            code = test.wait(timeout=180)
        except subprocess.TimeoutExpired:
            os.killpg(test.pid, signal.SIGKILL)
            test.wait(timeout=5)
            raise
        if code:
            raise subprocess.CalledProcessError(code, test.args)
    try:
        run_app('queue')
        if errors or server.poll() is None:
            raise RuntimeError('node outage was not triggered') from (errors[0] if errors else None)
        server = start()
        run_app('replay')
        with sqlite3.connect(env['MONASTACK_DB']) as connection:
            assert connection.execute("SELECT COUNT(*) FROM messages WHERE body='synthetic process restart message'").fetchone()[0] == 1
            first = connection.execute("SELECT body FROM messages WHERE body LIKE 'synthetic outage marker %'").fetchone()[0].split()[-1]
            second = connection.execute("SELECT body FROM messages WHERE body LIKE 'synthetic replay process %'").fetchone()[0].split()[-1]
            assert first.isdigit() and second.isdigit() and first != second
    finally:
        stop.set()
        watcher.join(timeout=5)
        if server.poll() is None:
            server.terminate()
            server.wait(timeout=5)
