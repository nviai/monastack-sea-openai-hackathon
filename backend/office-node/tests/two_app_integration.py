"""Run two separate macOS app test processes against one disposable node."""
import os
from pathlib import Path
import secrets
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

# The app signs in with the enrolled device token, not a password (ADR 0008).
os.environ.setdefault('MONASTACK_SIGN_IN', 'token')

root = Path(__file__).resolve().parents[3]
node_binary = root / 'backend/office-node/target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack-two-app-test-') as directory:
    tmp = Path(directory)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env = {**os.environ, 'MONASTACK_DB': str(tmp / 'office.sqlite3'),
           'MONASTACK_NODE_PORT': str(port), 'MONASTACK_TEST_ISOLATED_OUTBOX': '1',
           'MONASTACK_TEST_OUTBOX_SCOPE': secrets.token_hex(16)}
    credentials = {actor: secrets.token_hex(32) for actor in ('an', 'van')}
    for actor, credential in credentials.items():
        subprocess.run([str(node_binary), 'enroll', actor], env=env, input=credential,
                       text=True, check=True)
    apps = {}
    for actor in credentials:
        parent = tmp / actor
        parent.mkdir()
        (parent / 'core').symlink_to(root / 'core', target_is_directory=True)
        app = parent / 'app'
        shutil.copytree(root / 'app', app, symlinks=True,
                        ignore=shutil.ignore_patterns('build', '.dart_tool', 'ephemeral',
                                                      'Pods', 'xcuserdata', '.DS_Store'))
        config = app / 'macos/Runner/Configs/AppInfo.xcconfig'
        contents = config.read_text().replace('PRODUCT_NAME = monastack', f'PRODUCT_NAME = monastack_test_{actor}')
        contents = contents.replace('PRODUCT_BUNDLE_IDENTIFIER = com.example.monastack',
                                    f'PRODUCT_BUNDLE_IDENTIFIER = com.example.monastack.test.{actor}')
        config.write_text(contents)
        subprocess.run(['flutter', 'pub', 'get', '--offline'], cwd=app, env=env,
                       check=True, stdout=subprocess.DEVNULL, timeout=60)
        apps[actor] = app
    # Build the two copies one after the other: two full macOS builds signing
    # their frameworks at the same time can fail inside codesign. The test
    # runs below then only rebuild incrementally.
    # macOS codesign occasionally fails with "internal error in Code Signing
    # subsystem"; that transient error is retried, anything else fails.
    for app in apps.values():
        for attempt in range(3):
            build = subprocess.run(['flutter', 'build', 'macos', '--debug', '--no-pub',
                                    '-t', 'integration_test/two_clients_test.dart'],
                                   cwd=app, env=env, capture_output=True, text=True, timeout=600)
            output = build.stdout + build.stderr
            if build.returncode == 0:
                break
            if 'internal error in Code Signing subsystem' not in output or attempt == 2:
                print(output[-6000:])
                raise RuntimeError('macOS build failed')
            print('codesign internal error; rebuilding')
    server = subprocess.Popen([str(node_binary)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    server_holder = [server]
    stop = threading.Event()
    errors = []
    watcher = None
    processes = {}
    logs = {}
    try:
        for _ in range(100):
            if server.poll() is not None:
                raise RuntimeError('node failed to start')
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{port}/v1/me', timeout=.2)
            except urllib.error.HTTPError:
                break
            except OSError:
                time.sleep(.05)
        else:
            raise RuntimeError('node did not start')
        def restart_on_request():
            try:
                while not stop.wait(.1):
                    with sqlite3.connect(env['MONASTACK_DB'], timeout=2) as connection:
                        found = connection.execute("SELECT 1 FROM messages WHERE body='two-client restart request'").fetchone()
                    if found:
                        if stop.wait(2): return
                        server_holder[0].terminate()
                        server_holder[0].wait(timeout=5)
                        if stop.wait(12): return
                        server_holder[0] = subprocess.Popen([str(node_binary)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        return
            except Exception as error:
                errors.append(error)
        watcher = threading.Thread(target=restart_on_request, daemon=True)
        watcher.start()
        for actor, app in apps.items():
            log = (tmp / f'{actor}.log').open('w+')
            logs[actor] = log
            client_env = {**env, 'MONASTACK_TEST_ACTOR': actor,
                          'MONASTACK_TEST_CREDENTIAL': credentials[actor]}
            processes[actor] = subprocess.Popen(
                ['flutter', 'test', '--no-pub', 'integration_test/two_clients_test.dart', '-d', 'macos'],
                cwd=app, env=client_env, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 240
        while any(p.poll() is None for p in processes.values()) and time.monotonic() < deadline:
            if errors or any(p.poll() not in (None, 0) for p in processes.values()):
                break
            time.sleep(.2)
        if errors or any(p.poll() != 0 for p in processes.values()):
            for actor, log in logs.items():
                log.flush()
                log.seek(0)
                print(f'--- {actor} test output ---\n{log.read()[-8000:]}')
            raise RuntimeError('two-app integration failed or timed out')
        with sqlite3.connect(env['MONASTACK_DB']) as connection:
            assert connection.execute("SELECT COUNT(*) FROM messages WHERE body='two-client queued during outage'").fetchone()[0] == 1
        print('Two independent macOS apps: room chat, queued direct message, presence, movement, app rebuild and node restart passed')
    finally:
        stop.set()
        if watcher is not None: watcher.join(timeout=8)
        for process in processes.values():
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
        for log in logs.values(): log.close()
        if server_holder[0].poll() is None:
            server_holder[0].terminate()
            server_holder[0].wait(timeout=5)
