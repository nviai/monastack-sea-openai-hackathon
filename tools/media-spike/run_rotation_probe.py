"""Disposable two-server media rotation probe; synthetic data, internal Docker network only."""
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tempfile
import time
import uuid

SERVER_IMAGE = 'sha256:89ca9ce0791e18d6e03bf6e2c49ceb27e1c754eae8bd50c989386c1a5963791a'
CLIENT_IMAGE = os.environ.get('MONASTACK_MEDIA_PROBE_IMAGE', '')
if not re.fullmatch(r'sha256:[0-9a-f]{64}', CLIENT_IMAGE):
    raise SystemExit('Set MONASTACK_MEDIA_PROBE_IMAGE to a locally built probe image ID.')
base = 'monastack-rotation-' + uuid.uuid4().hex
network = base + '-network'
servers = [base + '-old', base + '-new']
client = base + '-client'
created_network = False
created = []
runner = None
keys = ['test' + secrets.token_hex(8) for _ in range(2)]
secrets_ = [secrets.token_hex(32) for _ in range(2)]
try:
    subprocess.run(['docker', 'network', 'create', '--internal', network], stdout=subprocess.DEVNULL,
                   stderr=subprocess.PIPE, check=True, timeout=20)
    created_network = True
    network_info = json.loads(subprocess.check_output(['docker', 'network', 'inspect', network], text=True))[0]
    subnet = ipaddress.ip_network(network_info['IPAM']['Config'][0]['Subnet'])
    ips = [str(subnet.network_address + offset) for offset in (10, 11)]
    with tempfile.TemporaryDirectory(prefix='monastack-media-rotation-') as directory:
        root = Path(directory)
        sync = root / 'sync'
        sync.mkdir(mode=0o777)
        sync.chmod(0o777)
        for index, name in enumerate(servers):
            config = root / f'server-{index}.yaml'
            config.write_text(f'port: 7880\nbind_addresses:\n  - "0.0.0.0"\nrtc:\n  tcp_port: 7881\n  udp_port: 7882\n  use_external_ip: false\nkeys:\n  {keys[index]}: {secrets_[index]}\n')
            config.chmod(0o600)
            subprocess.run(['docker', 'create', '--name', name, '--network', network, '--ip', ips[index],
                            '--mount', f'type=bind,source={config},target=/livekit.yaml,readonly',
                            SERVER_IMAGE, '--config', '/livekit.yaml', '--node-ip', ips[index]],
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True, timeout=30)
            created.append(name)
            subprocess.run(['docker', 'start', name], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                           check=True, timeout=20)
        time.sleep(1)
        # Docker Desktop may not share the workspace volume. Copy only the
        # synthetic probe script into the disposable test directory.
        script = root / 'rotation_client.py'
        shutil.copyfile(Path(__file__).resolve().with_name('rotation_client.py'), script)
        script.chmod(0o644)
        command = ['docker', 'create', '--name', client, '--network', network, '--read-only',
                   '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--pids-limit', '128',
                   '--memory', '512m', '--tmpfs', '/tmp:rw,noexec,nosuid,size=32m',
                   '--mount', f'type=bind,source={script},target=/probe/rotation_client.py,readonly',
                   '--mount', f'type=bind,source={sync},target=/sync', '--entrypoint', 'python',
                   '-e', f'PROBE_OLD_KEY={keys[0]}', '-e', f'PROBE_OLD_SECRET={secrets_[0]}',
                   '-e', f'PROBE_NEW_KEY={keys[1]}', '-e', f'PROBE_NEW_SECRET={secrets_[1]}',
                   '-e', f'PROBE_OLD_URL=ws://{ips[0]}:7880', '-e', f'PROBE_NEW_URL=ws://{ips[1]}:7880',
                   CLIENT_IMAGE, '/probe/rotation_client.py']
        result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=30)
        if result.returncode:
            raise RuntimeError('could not create isolated probe client')
        created.append(client)
        with (root / 'client.log').open('w+') as log:
            runner = subprocess.Popen(['docker', 'start', '--attach', client], stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 35
            while not (sync / 'ready').exists() and runner.poll() is None and time.monotonic() < deadline:
                time.sleep(.1)
            if not (sync / 'ready').exists():
                log.flush(); log.seek(0)
                raise RuntimeError('old epoch did not become ready: ' + log.read()[-2000:])
            subprocess.run(['docker', 'rm', '-f', servers[0]], stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, check=True, timeout=20)
            created.remove(servers[0])
            (sync / 'old-stopped').write_text('stopped')
            try:
                code = runner.wait(timeout=60)
            except subprocess.TimeoutExpired:
                runner.terminate()
                runner.wait(timeout=5)
                raise RuntimeError('rotation probe timed out') from None
            if code != 0 or not (sync / 'verified').exists():
                log.flush(); log.seek(0)
                raise RuntimeError('rotation probe failed: ' + log.read()[-3000:])
        print('Synthetic rotation passed: old server stopped, old token denied, new authorized audio received')
finally:
    if runner is not None and runner.poll() is None:
        runner.terminate()
        runner.wait(timeout=5)
    for name in reversed(created):
        result = subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=15, check=False)
        if result.returncode != 0:
            print('Warning: could not remove test container', name)
    if created_network:
        result = subprocess.run(['docker', 'network', 'rm', network], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=15, check=False)
        if result.returncode != 0:
            print('Warning: could not remove test network', network)
