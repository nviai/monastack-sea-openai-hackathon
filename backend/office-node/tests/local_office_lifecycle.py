"""Real CLI lifecycle matrix. Uses only this checkout's normal managed stack.

Stop the current owned stack first. Checks both Zellij availability modes with
Matrix, then both modes without Docker/Matrix. Restarts the normal visible stack
at the end. Never starts the app or a microphone/camera.
"""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
RUNTIME = ROOT / 'runtime'
EVIDENCE = RUNTIME / 'logs/fix-s-1'
EVIDENCE.mkdir(parents=True, exist_ok=True)
BASE = {**os.environ, 'MONASTACK_SERVER_HOST': '127.0.0.1'}
CLI = [sys.executable, str(ROOT / 'tools/local_office.py')]
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def cli(action, env, log, no_matrix=False):
    command = [*CLI, action, '--no-app', *(['--no-matrix'] if no_matrix else [])]
    result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=180)
    assert result.returncode == 0, f'{action} failed; inspect {log.name}'


def request(path, token=None):
    req = urllib.request.Request('http://127.0.0.1:47830' + path,
        headers={'Authorization': 'Bearer ' + token} if token else {})
    with OPENER.open(req, timeout=10) as result:
        return json.load(result)


def token_for_an():
    # Operator enrollment preserves identity and is passed over stdin, never argv.
    import secrets
    token = secrets.token_hex(32)
    env = {**BASE, 'MONASTACK_DB': str(RUNTIME / 'db/server-office.sqlite3')}
    subprocess.run([str(ROOT/'backend/office-node/target/debug/monastack-office-node'),'enroll','an'],
        input=token, text=True, env=env, check=True, capture_output=True)
    return token


def ports_closed():
    for port in (47830,47831,47840,8008,8009):
        with socket.socket() as connection:
            assert connection.connect_ex(('127.0.0.1',port)) != 0, f'port {port} remains open'


if __name__ == '__main__':
    tools = {name:shutil.which(name) for name in ('docker','zellij')}
    assert all(tools.values()), 'full lifecycle test requires Docker and Zellij installed'
    with (EVIDENCE/'lifecycle.log').open('w') as log:
        cli('stop', BASE, log)
        ports_closed()
        for matrix, zellij in [(True,True),(True,False),(False,True),(False,False)]:
            label=f'matrix={matrix}, zellij={zellij}'
            with tempfile.TemporaryDirectory(prefix='monastack-cli-path-') as bin_path:
                for name, enabled in [('docker',matrix),('zellij',zellij)]:
                    if enabled: (Path(bin_path)/name).symlink_to(tools[name])
                env={**BASE,'PATH':bin_path+':/usr/bin:/bin:/usr/sbin:/sbin'}
                assert bool(shutil.which('zellij',path=env['PATH'])) == zellij
                assert bool(shutil.which('docker',path=env['PATH'])) == matrix
                started=time.time()
                cli('start',env,log,no_matrix=not matrix)
                token=token_for_an()
                assert request('/v1/workspace')['role']=='master'
                assert request('/v1/chat/config',token)['enabled']==matrix
                pids={name:(RUNTIME/'pids'/f'{name}.pid').read_text() for name in ('server','client')}
                cli('start',env,log,no_matrix=not matrix)
                assert pids=={name:(RUNTIME/'pids'/f'{name}.pid').read_text() for name in ('server','client')},'repeat start duplicated nodes'
                cli('status',env,log,no_matrix=not matrix)
                if not zellij:
                    assert all((RUNTIME/'logs'/f'{name}.log').stat().st_mtime>=started for name in ('server','client'))
                    assert all('office node listening' in (RUNTIME/'logs'/f'{name}.log').read_text() for name in ('server','client'))
                cli('stop',env,log,no_matrix=not matrix)
                ports_closed()
            print('PASS '+label,flush=True)
            log.write('PASS '+label+'\n'); log.flush()
        # Cover --no-matrix while Docker is installed too (LiveKit still works).
        cli('start',BASE,log,no_matrix=True)
        assert request('/v1/chat/config',token_for_an())=={'enabled':False}
        cli('status',BASE,log,no_matrix=True)
        cli('stop',BASE,log,no_matrix=True)
        ports_closed()
        print('PASS --no-matrix with Docker installed',flush=True)
        cli('start',BASE,log)
        cli('status',BASE,log)
        print('PASS normal visible stack restored',flush=True)
