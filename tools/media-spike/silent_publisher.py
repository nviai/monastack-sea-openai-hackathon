"""Publish generated silence to a synthetic local LiveKit room; never opens a microphone."""
import asyncio
import json
import sys

from livekit import rtc

async def main():
    config = json.load(sys.stdin)
    room = rtc.Room()
    options = rtc.RoomOptions(auto_subscribe=False, rtc_config=rtc.RtcConfiguration(ice_servers=[]), connect_timeout=10)
    await room.connect(config['url'], config['token'], options)
    try:
        source = rtc.AudioSource(48000, 1)
        track = rtc.LocalAudioTrack.create_audio_track('synthetic-silence', source)
        await room.local_participant.publish_track(track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
        while True:
            await source.capture_frame(rtc.AudioFrame(bytes(960), 48000, 1, 480))
            await asyncio.sleep(.01)
    finally:
        await room.disconnect()

asyncio.run(main())
