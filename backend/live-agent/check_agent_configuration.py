"""Explicit paid integration: real text Mona tools, real ACLs, restored QA settings."""
import asyncio
import httpx2 as httpx

async def main():
    api=httpx.AsyncClient(base_url='http://127.0.0.1:47830',timeout=120)
    member=httpx.AsyncClient(base_url='http://127.0.0.1:47840',timeout=15)
    before=None
    try:
        for client,username in [(api,'triet.le'),(member,'hao.hua')]:
            r=await client.post('/v1/auth/login',json={'username':username,'password':'NviaiSeaxOpenAIHackathon','device':'Agent configuration smoke','platform':'test'})
            r.raise_for_status();client.headers['Authorization']='Bearer '+r.json()['access_token']
        r=await api.get('/v1/agent-configuration');r.raise_for_status()
        before=next(a for a in r.json()['agents'] if a['id']=='qa-agent')
        r=await member.get('/v1/agent-configuration');r.raise_for_status()
        assert not r.json()['can_manage']
        assert all('system_prompt' not in a['config'] for a in r.json()['agents'])
        r=await member.put('/v1/agent-configuration/qa-agent',json={'version':before['version'],'config':before['config']})
        assert r.status_code==403
        print('PASS: member proxy enforces read-only configuration and hides prompts.',flush=True)
        r=await api.post('/v1/agents/mona/chat',json={'messages':[{'role':'user','content':'Set QA Agent (qa-agent) to the cedar voice and male gender now. Inspect its configuration and change only these two fields; keep everything else unchanged. Use your agent management tool and confirm the actual result.'}]})
        r.raise_for_status()
        r=await api.get('/v1/agent-configuration');r.raise_for_status()
        after=next(a for a in r.json()['agents'] if a['id']=='qa-agent')
        assert after['config']['voice']=='cedar' and after['config']['gender']=='male'
        assert after['version']>before['version']
        r=await api.get('/v1/agent-configuration/audit');r.raise_for_status()
        assert any(a['agent']=='qa-agent' and a['source']=='mona' and a['version']==after['version'] for a in r.json())
        print('PASS: real OpenAI Responses tool calls through authenticated text Mona update QA configuration and audit the requesting administrator.',flush=True)
    finally:
        if before:
            r=await api.get('/v1/agent-configuration')
            if r.is_success:
                current=next(a for a in r.json()['agents'] if a['id']=='qa-agent')
                r=await api.put('/v1/agent-configuration/qa-agent',json={'version':current['version'],'config':before['config']})
                r.raise_for_status()
                print('Original QA configuration restored.',flush=True)
        for client in [member,api]:
            try: await client.post('/v1/auth/logout')
            except Exception: pass
            await client.aclose()

if __name__=='__main__':asyncio.run(main())
