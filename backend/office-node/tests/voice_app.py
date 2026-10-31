"""Drive the macOS app's voice against a real LiveKit server.

Run with the synthetic media environment:
    tools/media-spike/.venv/bin/python backend/office-node/tests/voice_app.py

A Python participant (actor `van`) publishes generated silence in the lobby;
the app (actor `an`) joins lobby voice muted, must receive that audio, and
must stop receiving it after walking to Dev & QA. No microphone is opened.
"""
import asyncio
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

from livekit import rtc

from realtime_client import Realtime

SERVER_IMAGE = 'sha256:89ca9ce0791e18d6e03bf6e2c49ceb27e1c754eae8bd50c989386c1a5963791a'
root = Path(__file__).resolve().parents[3]
node = root / 'backend/office-node/target/debug/monastack-office-node'


def free_port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


with tempfile.TemporaryDirectory(prefix='monastack-voice-app-') as directory:
    tmp = Path(directory)
    api_key, api_secret = 'dev' + secrets.token_hex(6), secrets.token_hex(32)
    signal_port, tcp_port, udp_port = free_port(), free_port(), free_port(socket.SOCK_DGRAM)
    config = tmp / 'livekit.yaml'
    config.write_text(
        f'port: {signal_port}\nbind_addresses: ["0.0.0.0"]\n'
        f'rtc:\n  tcp_port: {tcp_port}\n  udp_port: {udp_port}\n  use_external_ip: false\n'
        f'room:\n  auto_create: false\nkeys:\n  {api_key}: {api_secret}\n')
    config.chmod(0o600)
    key_file = tmp / 'media.key'
    key_file.write_text(f'{api_key} {api_secret}\n')
    key_file.chmod(0o600)
    container = 'monastack-voice-app-' + secrets.token_hex(4)
    subprocess.run(['docker', 'run', '-d', '--rm', '--name', container,
                    '-p', f'127.0.0.1:{signal_port}:{signal_port}',
                    '-p', f'127.0.0.1:{tcp_port}:{tcp_port}',
                    '-p', f'127.0.0.1:{udp_port}:{udp_port}/udp',
                    '--mount', f'type=bind,source={config},target=/livekit.yaml,readonly',
                    SERVER_IMAGE, '--config', '/livekit.yaml', '--node-ip', '127.0.0.1'],
                   check=True, stdout=subprocess.DEVNULL, timeout=60)
    port = free_port()
    env = {**os.environ, 'MONASTACK_DB': str(tmp / 'office.sqlite3'),
           'MONASTACK_NODE_PORT': str(port), 'MONASTACK_TEST_ISOLATED_OUTBOX': '1',
           'MONASTACK_MEDIA_URL': f'ws://127.0.0.1:{signal_port}',
           'MONASTACK_MEDIA_KEY_FILE': str(key_file)}
    tokens = {actor: secrets.token_hex(32) for actor in ('an', 'van')}
    for actor, token in tokens.items():
        subprocess.run([str(node), 'enroll', actor], env=env, input=token, text=True, check=True)
    server = subprocess.Popen([str(node)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    stop = threading.Event()
    try:
        for _ in range(100):
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{port}/v1/me', timeout=.2)
            except urllib.error.HTTPError:
                break
            except OSError:
                time.sleep(.05)
        van = Realtime(port, tokens['van'])
        session = secrets.token_hex(16)
        for _ in range(200):
            if van.request('GET', 'media/status')[1]['available']:
                break
            time.sleep(.1)

        def peer():
            async def run():
                seq = 0

                async def heartbeat():
                    nonlocal seq
                    while not stop.is_set():
                        seq += 1
                        van.publish(session, 'lobby', 13, 12, seq)
                        await asyncio.sleep(2)
                beat = asyncio.ensure_future(heartbeat())
                while True:
                    await asyncio.sleep(.5)
                    status, grant = van.request('POST', 'media/token', {'room': 'lobby', 'session': session})
                    if status == 200:
                        break
                room = rtc.Room()
                await room.connect(grant['url'], grant['token'], rtc.RoomOptions(
                    rtc_config=rtc.RtcConfiguration(ice_servers=[]), connect_timeout=10))
                source = rtc.AudioSource(48000, 1)
                track = rtc.LocalAudioTrack.create_audio_track('synthetic-silence', source)
                await room.local_participant.publish_track(
                    track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
                while not stop.is_set():
                    await source.capture_frame(rtc.AudioFrame(bytes(960), 48000, 1, 480))
                    await asyncio.sleep(.01)
                beat.cancel()
                await room.disconnect()
            asyncio.run(run())
        thread = threading.Thread(target=peer, daemon=True)
        thread.start()
        result = subprocess.run(
            ['flutter', 'test', 'integration_test/voice_test.dart', '-d', 'macos'],
            cwd=root / 'app', env={**env, 'MONASTACK_TEST_CREDENTIAL': tokens['an']},
            capture_output=True, text=True, timeout=600)
        output = result.stdout + result.stderr
        if result.returncode != 0:
            print(output[-6000:])
            raise SystemExit('voice app test failed')
        print('\n'.join(l for l in output.splitlines() if l.startswith('voice app:')))
        print('macOS app voice: joined muted, received synthetic peer audio, followed room and isolated it')
    finally:
        stop.set()
        server.terminate()
        server.wait(timeout=5)
        subprocess.run(['docker', 'rm', '-f', container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
