"""Kill a second real macOS app with SIGKILL and verify the first app expires it.

The victim runs from a copy of the app with its own bundle identifier so two
app processes can run at once. Only disposable credentials and data are used.
"""
import os
from pathlib import Path
import secrets
import shutil
import signal
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
node = root / 'backend/office-node/target/debug/monastack-office-node'
victim_name = 'monastack_test_crash_victim'
with tempfile.TemporaryDirectory(prefix='monastack-app-crash-') as directory:
    tmp = Path(directory)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env = {**os.environ, 'MONASTACK_DB': str(tmp / 'office.sqlite3'),
           'MONASTACK_NODE_PORT': str(port), 'MONASTACK_TEST_ISOLATED_OUTBOX': '1'}
    credentials = {actor: secrets.token_hex(32) for actor in ('an', 'van')}
    for actor, credential in credentials.items():
        subprocess.run([str(node), 'enroll', actor], env=env, input=credential, text=True, check=True)
    parent = tmp / 'victim'
    parent.mkdir()
    (parent / 'core').symlink_to(root / 'core', target_is_directory=True)
    victim_app = parent / 'app'
    shutil.copytree(root / 'app', victim_app, symlinks=True,
                    ignore=shutil.ignore_patterns('build', '.dart_tool', 'ephemeral', 'Pods',
                                                  'xcuserdata', '.DS_Store'))
    config = victim_app / 'macos/Runner/Configs/AppInfo.xcconfig'
    text = config.read_text().replace('PRODUCT_NAME = monastack', f'PRODUCT_NAME = {victim_name}')
    text = text.replace('PRODUCT_BUNDLE_IDENTIFIER = com.example.monastack',
                        'PRODUCT_BUNDLE_IDENTIFIER = com.example.monastack.test.crashvictim')
    config.write_text(text)
    subprocess.run(['flutter', 'pub', 'get', '--offline'], cwd=victim_app, env=env, check=True,
                   stdout=subprocess.DEVNULL, timeout=60)
    server = subprocess.Popen([str(node)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    stop = threading.Event()
    errors = []
    killed = []
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

        def kill_on_marker():
            try:
                while not stop.wait(.1):
                    with sqlite3.connect(env['MONASTACK_DB'], timeout=2) as connection:
                        found = connection.execute(
                            "SELECT 1 FROM messages WHERE body='app crash: kill victim'").fetchone()
                    if found:
                        # The app binary itself, not the flutter tool driving it.
                        pids = subprocess.run(
                            ['pgrep', '-f', f'{victim_name}.app/Contents/MacOS/{victim_name}'],
                            capture_output=True, text=True).stdout.split()
                        if not pids:
                            raise RuntimeError('victim app process not found')
                        for pid in pids:
                            os.kill(int(pid), signal.SIGKILL)
                        killed.extend(pids)
                        return
            except Exception as error:
                errors.append(error)
        watcher = threading.Thread(target=kill_on_marker, daemon=True)
        watcher.start()
        for role, actor, peer, cwd in (('observer', 'an', 'van', root / 'app'),
                                       ('victim', 'van', 'an', victim_app)):
            log = (tmp / f'{role}.log').open('w+')
            logs[role] = log
            processes[role] = subprocess.Popen(
                ['flutter', 'test', '--no-pub', 'integration_test/app_crash_test.dart', '-d', 'macos'],
                cwd=cwd, stdout=log, stderr=subprocess.STDOUT,
                env={**env, 'MONASTACK_TEST_ROLE': role, 'MONASTACK_TEST_PEER': peer,
                     'MONASTACK_TEST_ACTOR': actor,
                     'MONASTACK_TEST_CREDENTIAL': credentials[actor]})
        deadline = time.monotonic() + 600
        observer = processes['observer']
        while observer.poll() is None and time.monotonic() < deadline and not errors:
            time.sleep(.2)
        ok = observer.poll() == 0 and not errors and killed
        if not ok:
            for role, log in logs.items():
                log.flush()
                log.seek(0)
                print(f'--- {role} output ---\n{log.read()[-6000:]}')
            raise RuntimeError(f'app crash test failed: {errors}')
        with sqlite3.connect(env['MONASTACK_DB']) as connection:
            assert connection.execute(
                "SELECT 1 FROM messages WHERE body='app crash: expiry verified'").fetchone()
        logs['observer'].seek(0)
        timing = [line for line in logs['observer'].read().splitlines() if 'peer gone after' in line]
        print('Second macOS app killed with SIGKILL; observer removed its avatar:', *timing)
    finally:
        stop.set()
        for process in processes.values():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
        subprocess.run(['pkill', '-9', '-f', f'{victim_name}.app/Contents/MacOS/{victim_name}'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        server.terminate()
        server.wait(timeout=5)
        for log in logs.values():
            log.close()
