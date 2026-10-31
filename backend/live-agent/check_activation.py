"""Explicit paid activation-policy check. No host microphone/camera is opened."""
import asyncio
import contextlib
import sqlite3
import time
import uuid
import httpx2 as httpx
from livekit import rtc
from worker import ROOT

async def main():
    api=httpx.AsyncClient(base_url='http://127.0.0.1:47830',timeout=15)
    room=rtc.Room()
    rt=None
    original=None
    heartbeat=None
    session=str(uuid.uuid4())
    seq=0
    try:
        r=await api.post('/v1/auth/login',json={'username':'triet.le','password':'NviaiSeaxOpenAIHackathon','device':'Activation configuration smoke','platform':'test'})
        r.raise_for_status();api.headers['Authorization']='Bearer '+r.json()['access_token']
        r=await api.get('/v1/agent-configuration');r.raise_for_status()
        original=next(a for a in r.json()['agents'] if a['id']=='mona')
        config={**original['config'],'activation_mode':'automatic','idle_seconds':5,'muted_idle_seconds':2,'greeting':False}
        r=await api.put('/v1/agent-configuration/mona',json={'version':original['version'],'config':config});r.raise_for_status()
        r=await api.post('/v1/realtime/ticket',json={});r.raise_for_status()
        rt=httpx.AsyncClient(base_url=r.json()['realtime_url'],timeout=15)
        async def publish():
            nonlocal seq
            r=await api.post('/v1/realtime/ticket',json={});r.raise_for_status()
            rt.headers['Authorization']='Ticket '+r.json()['ticket']
            seq+=1
            r=await rt.post('/v1/presence',json={'session':session,'room':'lobby','x':14,'y':13,'seq':seq});r.raise_for_status()
        await publish()
        r=await rt.post('/v1/media/token',json={'session':session,'room':'lobby'});r.raise_for_status()
        await room.connect(r.json()['url'],r.json()['token'])
        async def keepalive():
            while True:
                await publish()
                await asyncio.sleep(3)
        heartbeat=asyncio.create_task(keepalive())
        def seconds():
            with sqlite3.connect('file:'+str(ROOT/'runtime/db/server-office.sqlite3')+'?mode=ro',uri=True) as db:
                row=db.execute("SELECT seconds FROM live_agent_sessions WHERE room='lobby' AND ended IS NULL ORDER BY started DESC LIMIT 1").fetchone()
                return row[0] if row else 0
        start=time.monotonic()
        while seconds()==0 and time.monotonic()-start<20:
            await asyncio.sleep(.25)
        assert seconds()>0,'Automatic mode must start Live even with the mic off'
        print('PASS: automatic room entry starts a paid session without microphone capture.',flush=True)
        for _ in range(100):
            r=await api.get('/v1/live-agents/rooms/lobby');r.raise_for_status()
            status=r.json()
            if status['state']=='ready' and seconds()>0:break
            await asyncio.sleep(.2)
        assert status['state']=='ready','Configured short muted timeout must close the session'
        assert status['activation_mode']=='automatic' and status['idle_seconds']==5 and status['muted_idle_seconds']==2
        stopped=seconds()
        await asyncio.sleep(6)
        assert seconds()==stopped,'A heartbeat must not continuously reopen automatic sessions'
        print('PASS: per-agent timeout closes Live and idle heartbeats do not reopen it.',flush=True)
    finally:
        if heartbeat:
            heartbeat.cancel();await asyncio.gather(heartbeat,return_exceptions=True)
        if rt:
            with contextlib.suppress(Exception):await rt.delete('/v1/presence/'+session)
            await rt.aclose()
        await room.disconnect()
        if original:
            r=await api.get('/v1/agent-configuration')
            if r.is_success:
                latest=next(a for a in r.json()['agents'] if a['id']=='mona')
                r=await api.put('/v1/agent-configuration/mona',json={'version':latest['version'],'config':original['config']})
                r.raise_for_status()
                print('Original Mona configuration restored.',flush=True)
        with contextlib.suppress(Exception):await api.post('/v1/auth/logout')
        await api.aclose()

if __name__=='__main__':asyncio.run(main())
