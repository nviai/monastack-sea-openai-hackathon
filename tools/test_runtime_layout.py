"""Verify runtime defaults, config loading and Docker mount paths without Docker."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

root = Path(__file__).resolve().parents[1]
binary = root/'backend/office-node/target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack runtime ') as directory:
    base = Path(directory)
    runtime = base/'runtime data'
    runtime.mkdir()
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    (runtime/'.env').write_text(f'MONASTACK_NODE_PORT={port}\nMONASTACK_REALTIME=off\nMONASTACK_SEED_COMPANY=0\n')
    env = dict(os.environ)
    for name in ['MONASTACK_DB','MONASTACK_ENV_FILE','MONASTACK_NODE_PORT','MONASTACK_REALTIME','MONASTACK_SEED_COMPANY','MONASTACK_DEV_DIR']:
        env.pop(name, None)
    env['MONASTACK_RUNTIME_DIR'] = str(runtime)
    node = subprocess.Popen([str(binary)], cwd=base, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(200):
            if node.poll() is not None:
                raise RuntimeError('node exited')
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/v1/workspace', timeout=.3) as response:
                    assert not json.load(response)['initialized']
                break
            except OSError:
                time.sleep(.05)
        else:
            raise RuntimeError('node startup timeout')
        assert (runtime/'db/office.sqlite3').is_file()
        assert not (base/'office.sqlite3').exists()
    finally:
        node.terminate()
        node.wait(timeout=5)
    explicit_db = base/'override/nested.sqlite3'
    subprocess.run([str(binary), 'setup-code'], cwd=base, env={**env,'MONASTACK_DB':str(explicit_db)}, check=True, capture_output=True)
    assert explicit_db.is_file()
    # Do not silently abandon a legacy workspace.
    legacy = base/'legacy'
    legacy.mkdir()
    (legacy/'office.sqlite3').write_bytes(b'legacy sentinel')
    refused = subprocess.run([str(binary),'setup-code'], cwd=legacy,
        env={**env,'MONASTACK_RUNTIME_DIR':str(legacy/'runtime')}, capture_output=True)
    assert refused.returncode != 0 and b'legacy database found' in refused.stderr
    assert (legacy/'office.sqlite3').read_bytes() == b'legacy sentinel'
    # Capture Docker arguments without launching any container or fetching images.
    bin_dir = base/'bin'
    bin_dir.mkdir()
    docker = bin_dir/'docker'
    docker.write_text('#!/usr/bin/env python3\nimport json,os,sys\nif sys.argv[1] == "run":\n open(os.environ["MOUNT_CAPTURE"],"w").write(json.dumps(sys.argv[1:]))\n')
    docker.chmod(0o755)
    capture = base/'docker-args.json'
    subprocess.run(['sh',str(root/'backend/media/livekit-dev.sh'),'start'],cwd=base,
        env={**env,'PATH':str(bin_dir)+os.pathsep+env['PATH'],'MOUNT_CAPTURE':str(capture)}, check=True, capture_output=True)
    args = json.loads(capture.read_text())
    assert args[args.index('--mount')+1] == f'type=bind,source={runtime}/media/livekit.yaml,target=/livekit.yaml,readonly'
    assert (runtime/'media/media.key').is_file()
    # Worker default scratch is inside the same runtime root.
    sys.path.insert(0,str(root/'backend/process-node'))
    import worker
    original_runtime = os.environ.get('MONASTACK_RUNTIME_DIR')
    os.environ['MONASTACK_RUNTIME_DIR'] = str(runtime)
    worker.request = lambda *args: []
    try:
        assert worker.once('http://127.0.0.1:1','synthetic','synthetic',[]) == 'no approved job'
        assert (runtime/'worker').is_dir()
    finally:
        if original_runtime is None:
            os.environ.pop('MONASTACK_RUNTIME_DIR',None)
        else:
            os.environ['MONASTACK_RUNTIME_DIR'] = original_runtime
print('Runtime layout: default DB/config, explicit override, legacy guard, media bind mount and worker scratch passed.')
