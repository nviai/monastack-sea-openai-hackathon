"""Presence lifecycle/selection smoke; no human RTC connection or capture devices."""
import asyncio
import contextlib
import json
import time
import uuid
import httpx2 as httpx
from worker import Authority, ROOT

async def main():
    api=httpx.AsyncClient(base_url='http://127.0.0.1:47830',timeout=10)
    authority=Authority()
    rt=None
    session=str(uuid.uuid4())
    token=None
    seq=0
    async def wait_status(room, agent=None, state='active'):
        for _ in range(100):
            r=await api.get('/v1/live-agents/rooms/'+room)
            r.raise_for_status()
            data=r.json()
            matches = data['state'] in {'ready','listening','speaking','working'} if state=='active' else data['state']==state
            if matches and (agent is None or data['selected']==agent):
                return data
            await asyncio.sleep(.2)
        raise AssertionError(f'{room}: expected {agent} {state}, got {data["state"]}')
    try:
        r=await api.post('/v1/auth/login',json={'username':'triet.le','password':'NviaiSeaxOpenAIHackathon','device':'Agent room smoke','platform':'test'})
        r.raise_for_status();token=r.json()['access_token']
        api.headers['Authorization']='Bearer '+token
        r=await api.post('/v1/realtime/ticket',json={});r.raise_for_status()
        rt=httpx.AsyncClient(base_url=r.json()['realtime_url'],timeout=10)
        spawns={r['id']:r['spawn'] for r in json.loads((ROOT/'data/seed/nviai/map.v2.json').read_text())['rooms']}
        async def enter(room):
            nonlocal seq
            r=await api.post('/v1/realtime/ticket',json={});r.raise_for_status()
            rt.headers['Authorization']='Ticket '+r.json()['ticket']
            seq+=1
            x,y=spawns[room]
            r=await rt.post('/v1/presence',json={'session':session,'room':room,'x':x,'y':y,'seq':seq});r.raise_for_status()
        for room,agent in [('dev','dev-agent'),('product','pm-agent'),('sales','sales-agent'),('support','cskh-agent'),('lobby','mona')]:
            await enter(room)
            await wait_status(room,agent)
            plans=await authority.call('rooms')
            ours=[p['room'] for p in plans['rooms'] if any(u['session']==session for u in p['users'])]
            assert ours==[room], ours
            print('PASS: presence drives one resident worker in',room,flush=True)
        await enter('dev')
        await wait_status('dev','dev-agent')
        r=await api.post('/v1/live-agents/rooms/dev',json={'action':'select','agent':'qa-agent'});r.raise_for_status()
        await wait_status('dev','qa-agent')
        print('PASS: Dev/QA handover selects one QA worker.',flush=True)
        r=await api.post('/v1/live-agents/rooms/dev',json={'action':'pause'});r.raise_for_status()
        await wait_status('dev',state='paused')
        assert not [p for p in (await authority.call('rooms'))['rooms'] if any(u['session']==session for u in p['users'])]
        r=await api.post('/v1/live-agents/rooms/dev',json={'action':'select','agent':'dev-agent'});r.raise_for_status()
        r=await api.post('/v1/live-agents/rooms/dev',json={'action':'resume'});r.raise_for_status()
        await enter('dev')
        await wait_status('dev','dev-agent')
        await enter('lounge')
        for _ in range(30):
            if not [p for p in (await authority.call('rooms'))['rooms'] if any(u['session']==session for u in p['users'])]:
                break
            await asyncio.sleep(.2)
        assert not [p for p in (await authority.call('rooms'))['rooms'] if any(u['session']==session for u in p['users'])]
        print('PASS: admin pause/resume, restored Dev selection, and non-agent room cleanup.',flush=True)
    finally:
        if rt:
            with contextlib.suppress(Exception): await rt.delete('/v1/presence/'+session)
            await rt.aclose()
        if token:
            with contextlib.suppress(Exception):
                await api.post('/v1/live-agents/rooms/dev',json={'action':'select','agent':'dev-agent'})
                await api.post('/v1/live-agents/rooms/dev',json={'action':'resume'})
            with contextlib.suppress(Exception): await api.post('/v1/auth/logout')
        await api.aclose()
        await authority.client.aclose()

if __name__=='__main__': asyncio.run(main())
