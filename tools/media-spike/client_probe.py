"""Synthetic LiveKit probe. Uses only random test identities and a generated tone."""
import asyncio
import math
import os
import struct

from livekit import api, rtc

KEY = os.environ['MONASTACK_MEDIA_TEST_KEY']
SECRET = os.environ['MONASTACK_MEDIA_TEST_SECRET']
URL = os.environ['MONASTACK_MEDIA_TEST_URL']
HTTP = URL.replace('ws://', 'http://', 1)


def token(identity, room, secret=SECRET):
    return (api.AccessToken(KEY, secret).with_identity(identity)
            .with_grants(api.VideoGrants(room_join=True, room=room, can_publish=True, can_subscribe=True))
            .to_jwt())


async def main():
    rooms=[]
    streams=[]
    counts={'member':0,'outsider':0,'revoked':0,'new_epoch':0}
    options=rtc.RoomOptions(auto_subscribe=True, rtc_config=rtc.RtcConfiguration(ice_servers=[]), connect_timeout=8)
    async def connect(identity, name, count_key=None, secret=SECRET, signed_token=None):
        room=rtc.Room()
        rooms.append(room)
        if count_key:
            @room.on('track_subscribed')
            def subscribed(track, publication, participant):
                if track.kind == rtc.TrackKind.KIND_AUDIO:
                    async def consume():
                        stream=rtc.AudioStream(track)
                        streams.append(stream)
                        async for event in stream:
                            if any(event.frame.data):
                                counts[count_key]+=1
                    asyncio.create_task(consume())
        await room.connect(URL,signed_token or token(identity,name,secret),options)
        return room
    async def publish(room):
        source=rtc.AudioSource(48000,1)
        track=rtc.LocalAudioTrack.create_audio_track('synthetic-tone',source)
        await room.local_participant.publish_track(track,rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
        async def tone():
            index=0
            while True:
                samples=[int(10000*math.sin(2*math.pi*440*(index+i)/48000)) for i in range(480)]
                frame=rtc.AudioFrame(struct.pack('<480h',*samples),48000,1,480)
                await source.capture_frame(frame)
                index+=480
                await asyncio.sleep(.01)
        return asyncio.create_task(tone())
    publisher_task=None
    try:
        publisher=await connect('synthetic-publisher','scope-epoch-one')
        member_token=token('synthetic-member','scope-epoch-one')
        member=await connect('synthetic-member','scope-epoch-one','member',signed_token=member_token)
        outsider=await connect('synthetic-outsider','other-scope','outsider')
        publisher_task=await publish(publisher)
        for _ in range(80):
            if counts['member']>5: break
            await asyncio.sleep(.1)
        assert counts['member']>5, f'authorized audio not received: {counts}'
        assert counts['outsider']==0, f'audio crossed rooms: {counts}'
        server=api.LiveKitAPI(HTTP,KEY,SECRET)
        try:
            await server.room.remove_participant(api.RoomParticipantIdentity(room='scope-epoch-one',identity='synthetic-member'))
            await asyncio.sleep(.4)
            # On a self-hosted server, the old signed token is expected to remain valid.
            revoked=await connect('synthetic-member','scope-epoch-one','revoked',signed_token=member_token)
            for _ in range(80):
                if counts['revoked']>5: break
                await asyncio.sleep(.1)
            assert counts['revoked']>5, f'old token did not receive old-room audio: {counts}'
            await server.room.delete_room(api.DeleteRoomRequest(room='scope-epoch-one'))
            publisher_task.cancel()
            await asyncio.gather(publisher_task,return_exceptions=True)
            publisher_task=None
            await asyncio.sleep(.5)
            stale=await connect('synthetic-member','scope-epoch-one','revoked',signed_token=member_token)
            next_room=await connect('synthetic-publisher','scope-epoch-two')
            next_member=await connect('synthetic-new-member','scope-epoch-two','new_epoch')
            publisher_task=await publish(next_room)
            for _ in range(80):
                if counts['new_epoch']>5: break
                await asyncio.sleep(.1)
            assert counts['new_epoch']>5, f'new epoch audio not received: {counts}'
            before=counts['revoked']
            await asyncio.sleep(1.5)
            assert counts['revoked']==before, f'old epoch received new epoch audio: {counts}'
            print('Synthetic media: same-room audio received; other room isolated; old token rejoined after removal; new room epoch isolated')
        finally:
            await server.aclose()
    finally:
        if publisher_task:
            publisher_task.cancel()
            await asyncio.gather(publisher_task,return_exceptions=True)
        await asyncio.gather(*(room.disconnect() for room in rooms),return_exceptions=True)
        await asyncio.gather(*(stream.aclose() for stream in streams),return_exceptions=True)

asyncio.run(main())
