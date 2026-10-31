"""Explicit paid Responses integration; fake authority prevents real workspace writes."""
import asyncio
from types import SimpleNamespace
from worker import Bridge, SAMPLES
import numpy as np

class Authority:
    def __init__(self):
        self.proposals=[]
    async def call(self,path,data):
        assert data['actor']=='an'
        if path=='context':
            return {'projects':[{'id':'synthetic-project','name':'Voice Test'}],'tasks':[]}
        assert path=='proposals'
        assert data['project']=='synthetic-project'
        self.proposals.append(data)
        return {'id':data['id'],'state':'pending','message':'Requires the requesting user to approve in the app. No task created yet.'}
class Channel:
    def __init__(self): self.messages=[]
    async def append(self,**data): self.messages.append(data)

async def main():
    authority=Authority()
    bridge=Bridge(authority,{'room':'lobby','agent':'mona','users':[{'actor':'an','session':'123456789012'}]}, {'idle_seconds':60,'session_seconds':600})
    bridge.claim={'lease':'synthetic-lease'}
    bridge.transcripts.append((0,2000,'an','Create a task named Verify the release in the Voice Test project.'))
    for _ in range(100):
        bridge.router.push('an.123456789012',np.full(SAMPLES,2000,dtype='<i2').tobytes())
        bridge.router.tick()
    commentary,thinking=Channel(),Channel()
    connection=SimpleNamespace(session=SimpleNamespace(commentary=commentary,thinking=thinking))
    try:
        await bridge.delegate(connection,'synthetic-delegation',2100)
        assert len(authority.proposals)==1, 'A verified task request should call the proposal tool once'
        assert commentary.messages and 'approve' in commentary.messages[-1]['content'].lower(), commentary.messages
        print('PASS: real Responses delegation proposes one task and requests app approval; no real workspace mutation.')
        authority.proposals.clear()
        bridge.router.roster([{'actor':'an','session':'123456789012'},{'actor':'van','session':'abcdefghijkl'}])
        bridge.router.samples=0
        bridge.router.history.clear()
        bridge.router.push('an.123456789012',np.full(SAMPLES,2000,dtype='<i2').tobytes())
        bridge.router.push('van.abcdefghijkl',np.full(SAMPLES,2000,dtype='<i2').tobytes())
        bridge.router.tick()
        await bridge.delegate(connection,'ambiguous-delegation',2100)
        assert not authority.proposals
        assert 'repeat' in commentary.messages[-1]['content']
        print('PASS: overlapping speakers cannot delegate a privileged action.')
    finally:
        await bridge.source.aclose()
        await bridge.openai.close()

if __name__=='__main__': asyncio.run(main())
