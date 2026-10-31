"""Paid, synthetic-only two-peer test. Never opens a microphone or camera."""
import asyncio
import contextlib
import json
import time
import uuid
import httpx2 as httpx
import numpy as np
from livekit import rtc
from openai import AsyncOpenAI
from worker import RATE, ROOT

async def main(setup=False):
    api = httpx.AsyncClient(base_url='http://127.0.0.1:47830', timeout=15)
    peers = []
    readers = []
    audio = [0, 0]
    heartbeat = None
    original = None
    try:
        for index, username in enumerate(['triet.le' if setup else 'pha.le', 'hao.hua']):
            r = await api.post('/v1/auth/login', json={'username': username, 'password': 'NviaiSeaxOpenAIHackathon', 'device': 'Synthetic voice smoke', 'platform': 'test'})
            r.raise_for_status()
            token = r.json()['access_token']
            r = await api.post('/v1/realtime/ticket', json={}, headers={'Authorization': 'Bearer '+token})
            r.raise_for_status()
            ticket = r.json()
            rt = httpx.AsyncClient(base_url=ticket['realtime_url'], headers={'Authorization': 'Ticket '+ticket['ticket']}, timeout=15)
            session = str(uuid.uuid4())
            room = rtc.Room()
            peer = dict(room=room, rt=rt, token=token, session=session, seq=0)
            peers.append(peer)
            async def consume(track, n):
                stream = rtc.AudioStream(track, sample_rate=RATE, num_channels=1)
                try:
                    async for event in stream:
                        a = np.frombuffer(event.frame.data, dtype=np.int16)
                        if np.max(np.abs(a.astype(np.int32))) > 100:
                            audio[n] += 1
                finally:
                    await stream.aclose()
            def make_handler(n):
                def handler(track, publication, participant):
                    if participant.identity.startswith('mona.'):
                        readers.append(asyncio.create_task(consume(track,n)))
                return handler
            room.on('track_subscribed', make_handler(index))
            peer['seq'] += 1
            r = await rt.post('/v1/presence', json={'session':session,'room':'lobby','x':14,'y':13,'seq':peer['seq']})
            r.raise_for_status()
            r = await rt.post('/v1/media/token', json={'session':session,'room':'lobby'})
            r.raise_for_status()
            grant = r.json()
            await room.connect(grant['url'], grant['token'])
        async def keepalive():
            while True:
                for peer in peers:
                    r = await api.post('/v1/realtime/ticket', json={}, headers={'Authorization':'Bearer '+peer['token']})
                    r.raise_for_status()
                    peer['rt'].headers['Authorization'] = 'Ticket '+r.json()['ticket']
                    peer['seq'] += 1
                    r = await peer['rt'].post('/v1/presence', json={'session':peer['session'],'room':'lobby','x':14,'y':13,'seq':peer['seq']})
                    r.raise_for_status()
                await asyncio.sleep(4)
        heartbeat = asyncio.create_task(keepalive())
        # Media and a bot may be connected without any paid Live session.
        for _ in range(80):
            if all(any(p.identity.startswith('mona.') for p in peer['room'].remote_participants.values()) for peer in peers):
                break
            await asyncio.sleep(.25)
        await asyncio.sleep(4)
        assert audio == [0,0], 'The agent must not greet or speak before an enabled microphone has speech'
        def usage():
            import sqlite3
            with sqlite3.connect('file:'+str(ROOT/'runtime/db/server-office.sqlite3')+'?mode=ro',uri=True) as db:
                return db.execute("SELECT seconds FROM live_agent_sessions WHERE room='lobby' AND ended IS NULL ORDER BY started DESC LIMIT 1").fetchone()[0]
        assert usage()==0, 'Presence/camera-only must not consume Live duration'
        print('PASS: connected receive-only clients, one agent, no greeting and zero Live duration before speech.',flush=True)
        bots = [[p.identity.split('.')[0] for p in peer['room'].remote_participants.values() if p.identity.startswith('mona.')] for peer in peers]
        assert bots == [['mona'], ['mona']], bots
        print('Exactly one shared Mona participant on both clients.', flush=True)
        if setup:
            r = await api.get('/v1/agent-configuration', headers={'Authorization':'Bearer '+peers[0]['token']})
            r.raise_for_status()
            original = next(a for a in r.json()['agents'] if a['id']=='qa-agent')
        # Send TTS synthetic audio only. No host capture device is accessed.
        client = AsyncOpenAI()
        speech = await client.audio.speech.create(model='gpt-4o-mini-tts', voice='alloy', input=('Hello Mona. Please configure QA Agent now: set its voice to cedar and its gender to male. Keep all other configuration unchanged. Please use your tools to apply this change.' if setup else 'Hello Mona. Please check the workspace and tell me which projects currently exist. Use your workspace tools to check the real data.'), response_format='pcm')
        pcm = speech.content
        source = rtc.AudioSource(RATE,1)
        track = rtc.LocalAudioTrack.create_audio_track('synthetic-human',source)
        await peers[0]['room'].local_participant.publish_track(track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
        await asyncio.sleep(1)
        for _ in range(100):
            await source.capture_frame(rtc.AudioFrame(bytes(960),RATE,1,480))
        await source.wait_for_playout()
        await asyncio.sleep(1)
        assert audio == [0,0] and usage()==0, 'An enabled but silent microphone must not open Live'
        track.mute()
        await asyncio.sleep(1)
        for _ in range(50):
            await source.capture_frame(rtc.AudioFrame(np.full(480,3000,dtype='<i2').tobytes(),RATE,1,480))
        await source.wait_for_playout()
        await asyncio.sleep(1)
        assert audio == [0,0] and usage()==0, 'Muted microphone input must not open Live'
        print('PASS: silent and muted microphone tracks do not open GPT-Live.',flush=True)
        track.unmute()
        await asyncio.sleep(1)
        before = audio.copy()
        for offset in range(0,len(pcm),960):
            chunk=pcm[offset:offset+960]
            await source.capture_frame(rtc.AudioFrame(chunk,RATE,1,len(chunk)//2))
        await source.wait_for_playout()
        await asyncio.sleep(18)
        print('Shared voice response frames:', [audio[i]-before[i] for i in range(2)], flush=True)
        assert all(audio[i] > before[i] + 5 for i in range(2)), 'Both clients must hear a response'
        track.mute()
        await source.aclose()
        await client.close()
        r = await api.get('/v1/live-agents/rooms/lobby',headers={'Authorization':'Bearer '+peers[0]['token']})
        r.raise_for_status()
        captions=r.json().get('captions') or []
        print('Caption speakers:', sorted({c['speaker'] for c in captions}), flush=True)
        assert any(c['speaker']==('le-triet' if setup else 'le-pha') for c in captions), 'Authenticated synthetic input must be transcribed'
        if setup:
            r = await api.get('/v1/agent-configuration', headers={'Authorization':'Bearer '+peers[0]['token']})
            r.raise_for_status()
            configured = next(a for a in r.json()['agents'] if a['id']=='qa-agent')
            assert configured['config']['voice']=='cedar' and configured['config']['gender']=='male', 'Voice Mona must apply the authorized configuration with its tool'
            assert configured['version'] > original['version']
            print('PASS: authorized administrator voice request through GPT-Live and Responses configured QA Agent.', flush=True)
        for _ in range(80):
            r=await api.get('/v1/live-agents/rooms/lobby',headers={'Authorization':'Bearer '+peers[0]['token']})
            if r.json().get('state')=='ready':
                break
            await asyncio.sleep(.25)
        assert r.json()['state']=='ready', 'The paid session must close after all mics are muted and the reply is complete'
        closed_usage=usage()
        await asyncio.sleep(3)
        assert abs(usage()-closed_usage)<.01, 'Waiting after closure must not accrue Live duration'
        print('PASS: paid session closed after mute; idle usage stays unchanged.',flush=True)
        print('PASS: real GPT-Live, two LiveKit peers, one bot, synthetic voice input and shared output.', flush=True)
    finally:
        if original and peers:
            with contextlib.suppress(Exception):
                headers={'Authorization':'Bearer '+peers[0]['token']}
                r=await api.get('/v1/agent-configuration',headers=headers)
                current=next(a for a in r.json()['agents'] if a['id']=='qa-agent')
                r=await api.put('/v1/agent-configuration/qa-agent',headers=headers,json={'version':current['version'],'config':original['config']})
                r.raise_for_status()
                print('Original QA configuration restored.',flush=True)
        if heartbeat:
            heartbeat.cancel()
            await asyncio.gather(heartbeat,return_exceptions=True)
        for task in readers:
            task.cancel()
        await asyncio.gather(*readers,return_exceptions=True)
        for peer in peers:
            with contextlib.suppress(Exception):
                await peer['rt'].delete('/v1/presence/'+peer['session'])
            await peer['room'].disconnect()
            await peer['rt'].aclose()
            with contextlib.suppress(Exception):
                await api.post('/v1/auth/logout',headers={'Authorization':'Bearer '+peer['token']})
        await api.aclose()

if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mona-setup',action='store_true',help='Use an administrator synthetic voice to configure QA and restore the original settings afterward')
    asyncio.run(main(parser.parse_args().mona_setup))
