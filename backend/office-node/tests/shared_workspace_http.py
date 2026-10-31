"""Shared member/master office: authority, chat, presence, policy and outage."""
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from realtime_client import Realtime

binary = Path(__file__).resolve().parents[1]/'target/debug/monastack-office-node'
def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0))
        return s.getsockname()[1]
def request(p, path, body=None, token=None):
    req=urllib.request.Request(f'http://127.0.0.1:{p}/v1/{path}',
        data=None if body is None else json.dumps(body).encode(),
        headers={'Content-Type':'application/json', **({'Authorization':'Bearer '+token} if token else {})})
    try:
        with urllib.request.urlopen(req,timeout=10) as res:
            raw=res.read()
            return res.status,json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        return e.code,e.read().decode()
with tempfile.TemporaryDirectory(prefix='monastack-shared-') as directory:
    root=Path(directory)
    (root/'.env').write_text('')
    master_port,rt_port,member_port,unused_rt=port(),port(),port(),port()
    common={**os.environ,'MONASTACK_ENV_FILE':str(root/'.env'),'MONASTACK_BIND_HOST':'127.0.0.1','MONASTACK_REALTIME':'embedded'}
    common.pop('MONASTACK_WORKSPACE_MODE',None)  # Verify shared is the default.
    master_env={**common,'MONASTACK_DB':str(root/'master.sqlite3'),'MONASTACK_NODE_PORT':str(master_port),'MONASTACK_REALTIME_PORT':str(rt_port),'MONASTACK_SEED_COMPANY':'1'}
    member_env={**common,'MONASTACK_DB':str(root/'member.sqlite3'),'MONASTACK_NODE_PORT':str(member_port),'MONASTACK_REALTIME_PORT':str(unused_rt),'MONASTACK_SEED_COMPANY':'0'}
    nodes=[]
    def start(env,p):
        proc=subprocess.Popen([str(binary)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        nodes.append(proc)
        for _ in range(300):
            if proc.poll() is not None: raise RuntimeError('node exited')
            try:
                if request(p,'workspace')[0]==200:return proc
            except OSError:pass
            time.sleep(.05)
        raise RuntimeError('startup timeout')
    def login(p,username):
        status,s=request(p,'auth/login',{'username':username,'password':'NviaiSeaxOpenAIHackathon','device':'Shared workspace test'})
        assert status==200
        return s['access_token']
    try:
        master=start(master_env,master_port)
        admin=login(master_port,'triet.le')
        _,join=request(master_port,'admin/nodes',{'name':'Synthetic shared member'},admin)
        subprocess.run([str(binary),'setup-code'],env=member_env,check=True,capture_output=True)
        subprocess.run([str(binary),'join',f'http://127.0.0.1:{master_port}'],env=member_env,input=join['code'],text=True,check=True,capture_output=True)
        start(member_env,member_port)
        a,b=login(master_port,'pha.le'),login(member_port,'hao.hua')
        direct=request(master_port,'me',token=a)[1]
        proxy=request(member_port,'me',token=b)[1]
        assert direct['authority_id']==proxy['authority_id']
        tickets=[request(p,'realtime/ticket',{},t)[1] for p,t in [(master_port,a),(member_port,b)]]
        assert tickets[0]['realtime_url']==tickets[1]['realtime_url']==f'http://127.0.0.1:{rt_port}'
        with socket.socket() as s:assert s.connect_ex(('127.0.0.1',unused_rt))!=0, 'member must not start a second realtime authority'
        rt_a,rt_b=Realtime(master_port,a),Realtime(member_port,b)
        sa,sb=str(uuid.uuid4()),str(uuid.uuid4())
        assert rt_a.publish(sa,'lobby',14,13,1)==204
        assert rt_b.publish(sb,'lobby',14,13,1)==204
        assert any(p['actor']=='hua-hao' for p in rt_a.presence())
        assert any(p['actor']=='le-pha' for p in rt_b.presence())
        message={'id':str(uuid.uuid4()),'body':'Synthetic shared message'}
        assert request(member_port,'messages/room%3Alobby',message,b)[0]==201
        assert any(m['id']==message['id'] for m in request(master_port,'messages/room%3Alobby',token=a)[1])
        assert request(member_port,'messages/room%3Afinance',token=b)[0]==403
        with sqlite3.connect(root/'master.sqlite3') as c:assert c.execute('SELECT COUNT(*) FROM messages').fetchone()[0]==1
        with sqlite3.connect(root/'member.sqlite3') as c:assert c.execute('SELECT COUNT(*) FROM messages').fetchone()[0]==0
        master.terminate();master.wait(timeout=5)
        assert request(member_port,'me',token=b)[0]==502, 'never fall back to stale local office state'
        print('Shared workspace: same authority/tickets, mutual presence, shared chat, policy checks, no local records/realtime and outage behavior passed.')
    finally:
        for proc in nodes:
            if proc.poll() is None:proc.terminate();proc.wait(timeout=5)
