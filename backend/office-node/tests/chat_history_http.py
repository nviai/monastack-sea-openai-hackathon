"""Read-only legacy pagination, isolation and revoked access on a disposable node."""
import json
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

root=Path(__file__).resolve().parents[3]
node=root/'backend/office-node/target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack-legacy-history-') as directory:
    database=Path(directory)/'office.sqlite3'
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0))
        port=sock.getsockname()[1]
    tokens={actor:secrets.token_hex(32) for actor in ('an','van')}
    env={**os.environ,'MONASTACK_DB':str(database),'MONASTACK_NODE_PORT':str(port),
         'MONASTACK_SEED_COMPANY':'0','MONASTACK_BIND_HOST':'127.0.0.1'}
    for actor,token in tokens.items():
        subprocess.run([str(node),'enroll',actor],env=env,input=token,text=True,check=True,capture_output=True)
    with sqlite3.connect(database) as conn:
        conn.executemany('INSERT INTO messages VALUES (?,?,?,?,?)',[(f'legacy-{i:04d}','room:lobby','an',f'earlier {i}',i) for i in range(205)])
        conn.execute("INSERT INTO messages VALUES ('legacy-private','room:finance','van','private',100)")
    server=subprocess.Popen([str(node)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        def request(actor,path,method='GET',body=None):
            req=urllib.request.Request(f'http://127.0.0.1:{port}/v1/'+path,method=method,
                data=None if body is None else json.dumps(body).encode(),
                headers={'Authorization':'Bearer '+tokens[actor],'Content-Type':'application/json'})
            try:
                with urllib.request.urlopen(req,timeout=3) as response:
                    data=response.read()
                    return response.status,json.loads(data) if data else None
            except urllib.error.HTTPError as error:
                return error.code,None
        for _ in range(100):
            try:
                if request('an','me')[0]==200:break
            except OSError:time.sleep(.05)
        else:raise RuntimeError('node did not start')
        latest=request('an','chat/legacy/room%3Alobby?limit=1000')[1]
        assert len(latest)==100 and [m['created'] for m in latest]==list(range(204,104,-1))
        older=request('an','chat/legacy/room%3Alobby?before=105&limit=100')[1]
        assert [m['created'] for m in older]==list(range(104,4,-1))
        assert set(latest[0])=={'id','sender_actor','sender_name','body','created'}
        assert request('an','chat/legacy/room%3Afinance')[0]==403
        assert request('van','chat/legacy/room%3Afinance')[1][0]['id']=='legacy-private'
        assert request('an','messages/room%3Alobby','POST',{'id':'never-write','body':'refused'})[0]==404
        subprocess.run([str(node),'room','revoke','finance','van'],env=env,check=True,capture_output=True)
        assert request('van','chat/legacy/room%3Afinance')[0]==403
        with sqlite3.connect(database) as conn:
            assert conn.execute('SELECT COUNT(*) FROM messages').fetchone()[0]==206
        print('Legacy HTTP: newest-first pages, limit bound, contract fields, retired writes and revocation passed')
    finally:
        server.terminate()
        server.wait(timeout=5)
