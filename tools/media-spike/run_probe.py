"""Isolated synthetic media test: no workspace records, credentials or microphone."""
import ipaddress
import json
import os
import re
import secrets
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

SERVER_IMAGE='sha256:89ca9ce0791e18d6e03bf6e2c49ceb27e1c754eae8bd50c989386c1a5963791a'
CLIENT_IMAGE=os.environ.get('MONASTACK_MEDIA_PROBE_IMAGE','')
if not re.fullmatch(r'sha256:[0-9a-f]{64}', CLIENT_IMAGE):
    raise SystemExit('Set MONASTACK_MEDIA_PROBE_IMAGE to the ID printed by docker build -q.')
name='monastack-media-'+uuid.uuid4().hex
network=name+'-network'
client=name+'-client'
created_network=False
created_server=False
created_client=False
key='test'+secrets.token_hex(8)
secret=secrets.token_hex(32)
try:
    subprocess.run(['docker','network','create','--internal',network],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,check=True,timeout=20)
    created_network=True
    info=json.loads(subprocess.check_output(['docker','network','inspect',network],text=True))[0]
    subnet=ipaddress.ip_network(info['IPAM']['Config'][0]['Subnet'])
    server_ip=str(subnet.network_address+10)
    with tempfile.TemporaryDirectory(prefix='monastack-media-test-') as directory:
        config=Path(directory)/'livekit.yaml'
        config.write_text(f'port: 7880\nbind_addresses:\n  - "0.0.0.0"\nrtc:\n  tcp_port: 7881\n  udp_port: 7882\n  use_external_ip: false\nkeys:\n  {key}: {secret}\n')
        config.chmod(0o600)
        command=['docker','create','--name',name,'--network',network,'--ip',server_ip,
                 '--mount',f'type=bind,source={config},target=/livekit.yaml,readonly',
                 SERVER_IMAGE,'--config','/livekit.yaml','--node-ip',server_ip]
        subprocess.run(command,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,check=True,timeout=30)
        created_server=True
        subprocess.run(['docker','start',name],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,check=True,timeout=20)
        time.sleep(1)
        command=['docker','create','--name',client,'--network',network,'--read-only',
                 '--cap-drop','ALL','--security-opt','no-new-privileges','--pids-limit','128',
                 '--memory','512m','--tmpfs','/tmp:rw,noexec,nosuid,size=32m',
                 '-e',f'MONASTACK_MEDIA_TEST_KEY={key}','-e',f'MONASTACK_MEDIA_TEST_SECRET={secret}',
                 '-e',f'MONASTACK_MEDIA_TEST_URL=ws://{server_ip}:7880',CLIENT_IMAGE]
        subprocess.run(command,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,check=True,timeout=30)
        created_client=True
        subprocess.run(['docker','start','--attach',client],check=True,timeout=55)
finally:
    if created_client:
        result=subprocess.run(['docker','rm','-f',client],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15,check=False)
        if result.returncode!=0: print('Warning: could not remove the test client',client)
    if created_server:
        result=subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15,check=False)
        if result.returncode!=0: print('Warning: could not remove the test server',name)
    if created_network:
        result=subprocess.run(['docker','network','rm',network],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15,check=False)
        if result.returncode!=0: print('Warning: could not remove the test network',network)
