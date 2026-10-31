"""Synthetic audio client for an isolated two-server credential rotation probe."""
import asyncio
import math
import os
from pathlib import Path
import struct

from livekit import api, rtc

OLD_KEY = os.environ['PROBE_OLD_KEY']
OLD_SECRET = os.environ['PROBE_OLD_SECRET']
NEW_KEY = os.environ['PROBE_NEW_KEY']
NEW_SECRET = os.environ['PROBE_NEW_SECRET']
OLD_URL = os.environ['PROBE_OLD_URL']
NEW_URL = os.environ['PROBE_NEW_URL']
SYNC = Path('/sync')

def token(key, secret, identity, room='synthetic-room'):
    return (api.AccessToken(key, secret).with_identity(identity)
            .with_grants(api.VideoGrants(room_join=True, room=room,
                                        can_publish=True, can_subscribe=True)).to_jwt())

async def main():
    rooms = []
    streams = []
    counts = {'old': 0, 'new': 0, 'outsider': 0}
    options = rtc.RoomOptions(auto_subscribe=True, rtc_config=rtc.RtcConfiguration(ice_servers=[]), connect_timeout=5)
    async def connect(url, signed, label=None):
        room = rtc.Room()
        rooms.append(room)
        if label:
            @room.on('track_subscribed')
            def subscribed(track, publication, participant):
                if track.kind == rtc.TrackKind.KIND_AUDIO:
                    async def consume():
                        stream = rtc.AudioStream(track)
                        streams.append(stream)
                        async for event in stream:
                            if any(event.frame.data):
                                counts[label] += 1
                    asyncio.create_task(consume())
        await room.connect(url, signed, options)
        return room
    async def publish(room):
        source = rtc.AudioSource(48000, 1)
        track = rtc.LocalAudioTrack.create_audio_track('synthetic-tone', source)
        await room.local_participant.publish_track(track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
        async def tone():
            index = 0
            while True:
                samples = [int(10000 * math.sin(2 * math.pi * 440 * (index + i) / 48000)) for i in range(480)]
                await source.capture_frame(rtc.AudioFrame(struct.pack('<480h', *samples), 48000, 1, 480))
                index += 480
                await asyncio.sleep(.01)
        return asyncio.create_task(tone())
    tasks = []
    try:
        old_token = token(OLD_KEY, OLD_SECRET, 'synthetic-revoked')
        old_publisher_token = token(OLD_KEY, OLD_SECRET, 'synthetic-publisher')
        old_publisher = await connect(OLD_URL, old_publisher_token)
        await connect(OLD_URL, old_token, 'old')
        tasks.append(await publish(old_publisher))
        for _ in range(80):
            if counts['old'] > 5:
                break
            await asyncio.sleep(.1)
        assert counts['old'] > 5, 'old epoch did not deliver synthetic audio'
        (SYNC / 'ready').write_text('ready')
        for _ in range(100):
            if (SYNC / 'old-stopped').exists():
                break
            await asyncio.sleep(.1)
        else:
            raise AssertionError('old instance was not stopped')
        # A WebRTC client may report connected until transport timeouts expire;
        # verify actual audio stops rather than trusting that status.
        await asyncio.sleep(1)
        old_count = counts['old']
        await asyncio.sleep(1.5)
        assert counts['old'] == old_count, 'old listener still received audio'
        for url in (OLD_URL, NEW_URL):
            try:
                await connect(url, old_token)
            except rtc.ConnectError:
                pass
            else:
                raise AssertionError('old token connected after rotation')
        next_publisher = await connect(NEW_URL, token(NEW_KEY, NEW_SECRET, 'synthetic-publisher'))
        await connect(NEW_URL, token(NEW_KEY, NEW_SECRET, 'synthetic-authorized'), 'new')
        await connect(NEW_URL, token(NEW_KEY, NEW_SECRET, 'synthetic-outsider', 'other-room'), 'outsider')
        tasks.append(await publish(next_publisher))
        for _ in range(80):
            if counts['new'] > 5:
                break
            await asyncio.sleep(.1)
        assert counts['new'] > 5, 'new epoch did not deliver synthetic audio'
        # Retry the stale token after the new instance has demonstrated audio
        # delivery, so a dead replacement server cannot explain its rejection.
        for stale in (old_token, old_publisher_token):
            try:
                await connect(NEW_URL, stale)
            except rtc.ConnectError:
                pass
            else:
                raise AssertionError('old token entered the active replacement server')
        await asyncio.sleep(1.5)
        assert counts['old'] == old_count, 'old listener received replacement audio'
        assert counts['outsider'] == 0, 'other room received synthetic audio'
        (SYNC / 'verified').write_text('verified')
        print('Synthetic media rotation: old server stopped, old token denied, new authorized audio received')
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await asyncio.gather(*(room.disconnect() for room in rooms), return_exceptions=True)
        await asyncio.gather(*(stream.aclose() for stream in streams), return_exceptions=True)

asyncio.run(main())
