"""Connect a disposable Flutter/macOS SDK client to synthetic loopback media.

Run using tools/media-spike/.venv/bin/python. Only generated silence and random
test credentials are used. A fixed relay listens on 127.0.0.1 only and reaches
an internal Docker network; ICE has no STUN/TURN servers. The generated project
contains no workspace files or seed.
"""
import ipaddress
import json
import os
from pathlib import Path
import secrets
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid

from livekit import api
from loopback_relay import LoopbackRelay

def interrupted(_signum, _frame):
    raise KeyboardInterrupt

signal.signal(signal.SIGTERM, interrupted)

SERVER_IMAGE = 'sha256:89ca9ce0791e18d6e03bf6e2c49ceb27e1c754eae8bd50c989386c1a5963791a'
CLIENT_IMAGE = os.environ.get('MONASTACK_MEDIA_PROBE_IMAGE', '')
if not re.fullmatch(r'sha256:[0-9a-f]{64}', CLIENT_IMAGE):
    raise SystemExit('Set MONASTACK_MEDIA_PROBE_IMAGE to a locally built probe image ID.')
root = Path(__file__).resolve().parent
name = 'monastack-sdk-loopback-' + uuid.uuid4().hex
network = name + '-network'
relay_name = name + '-relay'
env = {**os.environ, 'COCOAPODS_DISABLE_STATS': 'true', 'FLUTTER_SUPPRESS_ANALYTICS': 'true'}
key = 'test' + secrets.token_hex(8)
secret = secrets.token_hex(32)
def token(identity, publish, room='synthetic-room'):
    return (api.AccessToken(key, secret).with_identity(identity)
            .with_grants(api.VideoGrants(room_join=True, room=room,
                                        can_publish=publish, can_subscribe=True)).to_jwt())
publisher_token = token('synthetic-publisher', True)
receiver_token = token('synthetic-receiver', False)
outsider_token = token('synthetic-outsider', False, 'other-room')

def run(command, cwd=None, environment=env, timeout=180, log=None):
    process = subprocess.Popen(command, cwd=cwd, env=environment, start_new_session=True,
                               stdout=log, stderr=subprocess.STDOUT if log else None)
    try:
        code = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        raise RuntimeError('synthetic SDK probe timed out') from None
    except BaseException:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
        raise
    if code:
        raise RuntimeError(f'synthetic SDK probe failed at {command[1]} (exit {code})')

def free_port(kind):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

created_network = False
created_server = False
created_relay = False
relays = []
publisher = None
try:
    with tempfile.TemporaryDirectory(prefix='monastack-sdk-loopback-') as directory:
        tmp = Path(directory)
        project = tmp / 'app'
        run(['flutter', 'create', '--no-pub', '--platforms=macos', '--project-name', 'monastack_media_probe', str(project)])
        spec = project / 'pubspec.yaml'
        text = spec.read_text()
        assert text.count('\ndependencies:\n') == 1 and text.count('\ndev_dependencies:\n') == 1
        text = text.replace('\ndependencies:\n', '\ndependencies:\n  livekit_client: 2.13.1\n', 1)
        text = text.replace('\ndev_dependencies:\n', '\ndev_dependencies:\n  integration_test:\n    sdk: flutter\n', 1)
        spec.write_text(text)
        (project / 'lib/main.dart').write_text("import 'package:flutter/material.dart';\nvoid main() => runApp(const MaterialApp(home: Text('Synthetic media probe')));\n")
        tests = project / 'integration_test'
        tests.mkdir()
        shutil.copyfile(root / 'flutter_receiver_test.dart', tests / 'flutter_receiver_test.dart')
        entitlements = project / 'macos/Runner/DebugProfile.entitlements'
        text = entitlements.read_text()
        assert '<dict>' in text
        entitlements.write_text(text.replace('<dict>', '<dict>\n\t<key>com.apple.security.network.client</key>\n\t<true/>', 1))
        run(['flutter', 'pub', 'get', '--offline'], cwd=project)
        tcp_ports = set()
        while len(tcp_ports) < 2:
            tcp_ports.add(free_port(socket.SOCK_STREAM))
        signal_port, rtc_tcp = tuple(tcp_ports)
        rtc_udp = free_port(socket.SOCK_DGRAM)
        config = tmp / 'livekit.yaml'
        config.write_text(f'port: {signal_port}\nbind_addresses:\n  - "0.0.0.0"\nrtc:\n  tcp_port: {rtc_tcp}\n  udp_port: {rtc_udp}\n  use_external_ip: false\nkeys:\n  {key}: {secret}\n')
        config.chmod(0o600)
        subprocess.run(['docker', 'network', 'create', '--internal', network], stdout=subprocess.DEVNULL,
                       stderr=subprocess.PIPE, check=True, timeout=20)
        created_network = True
        network_info = json.loads(subprocess.check_output(['docker', 'network', 'inspect', network], text=True))[0]
        subnet = ipaddress.ip_network(network_info['IPAM']['Config'][0]['Subnet'])
        server_ip = str(subnet.network_address + 10)
        subprocess.run(['docker', 'create', '--name', name, '--network', network, '--ip', server_ip,
                        '--mount', f'type=bind,source={config},target=/livekit.yaml,readonly',
                        SERVER_IMAGE, '--config', '/livekit.yaml', '--node-ip', '127.0.0.1'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True, timeout=30)
        created_server = True
        subprocess.run(['docker', 'start', name], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True, timeout=20)
        subprocess.run(['docker', 'create', '--name', relay_name, '--network', network, '--read-only',
                        '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--pids-limit', '128',
                        '--memory', '256m', '--entrypoint', 'python', CLIENT_IMAGE, '-c',
                        'import time; time.sleep(600)'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True, timeout=30)
        created_relay = True
        subprocess.run(['docker', 'start', relay_name], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True, timeout=20)
        relays.append(LoopbackRelay(relay_name, server_ip, signal_port))
        relays.append(LoopbackRelay(relay_name, server_ip, rtc_tcp))
        url = f'ws://127.0.0.1:{signal_port}'
        for _ in range(30):
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{signal_port}', timeout=2):
                    pass
                break
            except urllib.error.HTTPError:
                break
            except OSError:
                time.sleep(.1)
        else:
            output = subprocess.run(['docker', 'logs', name], capture_output=True, text=True, timeout=10).stdout
            print(output[-2000:].replace(secret, '[synthetic secret]').replace(key, '[synthetic key]'))
            raise RuntimeError('synthetic loopback server did not start')
        publisher = subprocess.Popen([os.sys.executable, str(root / 'silent_publisher.py')], stdin=subprocess.PIPE,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
        publisher.stdin.write(json.dumps({'url': url, 'token': publisher_token}))
        publisher.stdin.close()
        time.sleep(2)
        if publisher.poll() is not None:
            raise RuntimeError('synthetic publisher failed to start')
        with (tmp / 'flutter.log').open('w+') as log:
            try:
                run(['flutter', 'test', 'integration_test/flutter_receiver_test.dart', '-d', 'macos'], cwd=project,
                    environment={**env, 'PROBE_URL': url, 'PROBE_RECEIVER_TOKEN': receiver_token,
                                 'PROBE_OUTSIDER_TOKEN': outsider_token}, timeout=240, log=log)
            except Exception:
                log.flush(); log.seek(0)
                output = log.read()[-4000:].replace(receiver_token, '[synthetic token]').replace(outsider_token, '[synthetic token]').replace(secret, '[synthetic secret]')
                print(output)
                raise
            log.flush(); log.seek(0)
            output = log.read()
            if 'FLUTTER_MEDIA_SUBSCRIPTION_VERIFIED' not in output or 'All tests passed!' not in output:
                raise RuntimeError('Flutter receiver did not confirm synthetic media')
        if publisher.poll() is not None:
            raise RuntimeError('synthetic publisher exited unexpectedly')
        print('Flutter/macOS SDK received synthetic silent RTP, published no local audio, and saw no track in the other room')
finally:
    if publisher is not None and publisher.poll() is None:
        os.killpg(publisher.pid, signal.SIGTERM)
        try:
            publisher.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(publisher.pid, signal.SIGKILL)
            publisher.wait(timeout=5)
    for relay in relays:
        relay.close()
    if created_relay:
        result = subprocess.run(['docker', 'rm', '-f', relay_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)
        if result.returncode:
            print('Warning: could not remove test relay', relay_name)
    if created_server:
        result = subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)
        if result.returncode:
            print('Warning: could not remove test server', name)
    if created_network:
        result = subprocess.run(['docker', 'network', 'rm', network], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15, check=False)
        if result.returncode:
            print('Warning: could not remove test network', network)
