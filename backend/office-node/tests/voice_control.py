"""Adversarial voice tests against a real self-hosted LiveKit server.

Run with the synthetic media environment, which provides the LiveKit SDK:
    tools/media-spike/.venv/bin/python backend/office-node/tests/voice_control.py

Uses Docker image livekit/livekit-server:v1.13.10 (pinned by digest), random
ephemeral credentials, generated silence and no microphone. The server only
listens on 127.0.0.1 and is removed afterwards.
"""
import asyncio
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

from livekit import rtc

from realtime_client import Realtime, ticket

SERVER_IMAGE = 'sha256:89ca9ce0791e18d6e03bf6e2c49ceb27e1c754eae8bd50c989386c1a5963791a'
root = Path(__file__).resolve().parents[3]
node = root / 'backend/office-node/target/debug/monastack-office-node'


def free_port(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def eventually(check, seconds, label):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.1)
    raise AssertionError(label)


class Listener:
    """A LiveKit participant that counts received audio frames."""

    def __init__(self):
        self.room = rtc.Room()
        self.frames = 0
        self.disconnected = asyncio.Event()
        self.room.on('track_subscribed', self._subscribed)
        self.room.on('disconnected', lambda *_: self.disconnected.set())

    def _subscribed(self, track, *_):
        async def read():
            async for _ in rtc.AudioStream(track):
                self.frames += 1
        asyncio.ensure_future(read())

    async def join(self, grant):
        await self.room.connect(grant['url'], grant['token'], rtc.RoomOptions(
            rtc_config=rtc.RtcConfiguration(ice_servers=[]), connect_timeout=10))
        return self


class Speaker(Listener):
    async def join(self, grant):
        await super().join(grant)
        source = rtc.AudioSource(48000, 1)
        track = rtc.LocalAudioTrack.create_audio_track('synthetic-silence', source)
        await self.room.local_participant.publish_track(
            track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))

        async def feed():
            while True:
                await source.capture_frame(rtc.AudioFrame(bytes(960), 48000, 1, 480))
                await asyncio.sleep(.01)
        self.feeder = asyncio.ensure_future(feed())
        return self


async def refused(grant):
    room = rtc.Room()
    try:
        await room.connect(grant['url'], grant['token'], rtc.RoomOptions(
            rtc_config=rtc.RtcConfiguration(ice_servers=[]), connect_timeout=5))
    except Exception:
        return True
    await room.disconnect()
    return False


def main():
    with tempfile.TemporaryDirectory(prefix='monastack-voice-') as directory:
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
        name = 'monastack-voice-' + secrets.token_hex(4)
        subprocess.run(['docker', 'run', '-d', '--rm', '--name', name,
                        '-p', f'127.0.0.1:{signal_port}:{signal_port}',
                        '-p', f'127.0.0.1:{tcp_port}:{tcp_port}',
                        '-p', f'127.0.0.1:{udp_port}:{udp_port}/udp',
                        '--mount', f'type=bind,source={config},target=/livekit.yaml,readonly',
                        SERVER_IMAGE, '--config', '/livekit.yaml', '--node-ip', '127.0.0.1'],
                       check=True, stdout=subprocess.DEVNULL, timeout=60)
        port = free_port()
        env = {**os.environ, 'MONASTACK_DB': str(tmp / 'office.sqlite3'),
               'MONASTACK_NODE_PORT': str(port),
               'MONASTACK_MEDIA_URL': f'ws://127.0.0.1:{signal_port}',
               'MONASTACK_MEDIA_KEY_FILE': str(key_file)}
        tokens = {actor: secrets.token_hex(32) for actor in ('an', 'van')}
        for actor, token in tokens.items():
            subprocess.run([str(node), 'enroll', actor], env=env, input=token, text=True, check=True)
        server = None

        def start():
            process = subprocess.Popen([str(node)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(100):
                try:
                    urllib.request.urlopen(f'http://127.0.0.1:{port}/v1/me', timeout=.2)
                except urllib.error.HTTPError:
                    return process
                except OSError:
                    time.sleep(.05)
            raise RuntimeError('node did not start')
        try:
            server = start()
            an, van = Realtime(port, tokens['an']), Realtime(port, tokens['van'])
            eventually(lambda: an.request('GET', 'media/status')[1]['available'], 20, 'media ready')
            sessions = {key: secrets.token_hex(16) for key in ('an', 'van-lobby', 'van-fin', 'van-fin2')}
            assert an.publish(sessions['an'], 'lobby', 14, 13, 1) == 204
            assert van.publish(sessions['van-lobby'], 'lobby', 13, 12, 1) == 204
            assert van.publish(sessions['van-fin'], 'finance', 25, 23, 1) == 204
            assert van.publish(sessions['van-fin2'], 'finance', 26, 23, 1) == 204

            def grant(client, room, session):
                return client.request('POST', 'media/token', {'room': room, 'session': session})

            status, lobby_an = grant(an, 'lobby', sessions['an'])
            assert status == 200, status
            assert grant(an, 'finance', sessions['an'])[0] == 403, 'non-member finance token'
            assert grant(van, 'finance', sessions['van-lobby'])[0] == 409, 'token for a room not entered'
            assert grant(an, 'lobby', sessions['van-lobby'])[0] == 409, 'token for another actor session'
            _, lobby_van = grant(van, 'lobby', sessions['van-lobby'])
            _, finance_van = grant(van, 'finance', sessions['van-fin'])
            _, finance_van2 = grant(van, 'finance', sessions['van-fin2'])
            assert finance_van['room'] != lobby_an['room']
            print('Voice tokens: member, non-member, not-present and other-session cases checked')

            async def media():
                lobby_listener = await Listener().join(lobby_an)
                lobby_speaker = await Speaker().join(lobby_van)
                fin_listener = await Listener().join(finance_van2)
                fin_speaker = await Speaker().join(finance_van)
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline and (lobby_listener.frames < 20 or fin_listener.frames < 20):
                    await asyncio.sleep(.1)
                assert lobby_listener.frames >= 20, 'lobby audio received'
                assert fin_listener.frames >= 20, 'finance audio received by a member'
                # The lobby listener hears exactly one remote publisher: not finance.
                remote = [p for p in lobby_listener.room.remote_participants.values() if p.track_publications]
                assert [p.identity.split('.')[0] for p in remote] == ['van']
                assert all(p.identity == lobby_speaker.room.local_participant.identity for p in remote)
                print('Voice media: lobby and finance audio delivered, rooms isolated')

                # Revoking finance membership deletes the media room: connected
                # finance participants are dropped and the old token is useless.
                subprocess.run([str(node), 'room', 'revoke', 'finance', 'van'], env=env, check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                revoked = time.monotonic()
                await asyncio.wait_for(fin_listener.disconnected.wait(), 10)
                await asyncio.wait_for(fin_speaker.disconnected.wait(), 10)
                print(f'Voice revocation: finance participants disconnected after {time.monotonic() - revoked:.1f}s')
                assert await refused(finance_van), 'stale finance token rejoined'
                assert grant(van, 'finance', sessions['van-fin'])[0] in (401, 403, 409)
                # The access epoch is global, so lobby voice also rotated; new
                # lobby tokens work and old ones do not.
                await asyncio.wait_for(lobby_listener.disconnected.wait(), 10)
                assert await refused(lobby_an), 'stale lobby token rejoined after rotation'
                assert an.publish(sessions['an'], 'lobby', 14, 13, 2) == 204
                assert van.publish(sessions['van-lobby'], 'lobby', 13, 12, 2) == 204
                _, fresh = grant(an, 'lobby', sessions['an'])
                assert fresh['room'] != lobby_an['room']
                listener = await Listener().join(fresh)
                # Walking out of the room removes the participant.
                assert an.publish(sessions['an'], 'dev', 3, 3, 3) == 204
                await asyncio.wait_for(listener.disconnected.wait(), 10)
                print('Voice room exit: participant removed when presence left the room')
                for client in (lobby_speaker, fin_speaker):
                    client.feeder.cancel()
                for client in (lobby_listener, lobby_speaker, fin_listener, fin_speaker, listener):
                    await client.room.disconnect()
                return fresh

            last = asyncio.run(media())
            # After a node restart, rooms from the previous run are deleted
            # before any token is issued, so earlier tokens cannot join.
            server.terminate()
            server.wait(timeout=5)
            server = start()
            eventually(lambda: an.request('GET', 'media/status')[1]['available'], 20, 'media ready after restart')
            assert asyncio.run(refused(last)), 'token from before restart rejoined'
            assert an.request('POST', 'media/token', {'room': 'lobby', 'session': sessions['an']})[0] == 409
            print('Voice control plane against LiveKit: authorization, isolation, revocation, room exit and restart passed')
        finally:
            if server is not None:
                server.terminate()
                server.wait(timeout=5)
            subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


main()
