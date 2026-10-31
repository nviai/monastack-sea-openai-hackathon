"""Test financial write contention between two local nodes on one synthetic DB."""
import concurrent.futures
import hashlib
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
def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0)); return s.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='monastack-finance-race-') as directory:
    db=Path(directory)/'office.sqlite3'
    base_env={**os.environ,'MONASTACK_DB':str(db)}
    tokens={name:secrets.token_hex(32) for name in ('an','van','mai')}
    for name,token in tokens.items():
        subprocess.run([str(node),'enroll',name],env=base_env,input=token,text=True,check=True)
    ports=[]
    while len(ports)<2:
        port=free_port()
        if port not in ports: ports.append(port)
    nodes=[]
    def request(index,who,method,path,body=None):
        req=urllib.request.Request(f'http://127.0.0.1:{ports[index]}/v1/{path}',data=None if body is None else json.dumps(body).encode(),method=method,headers={'Authorization':'Bearer '+tokens[who],'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(req,timeout=5) as response:
                raw=response.read(); return response.status,json.loads(raw) if raw else None
        except urllib.error.HTTPError as error: return error.code,None
    def op(): return secrets.token_hex(16)
    try:
        for port in ports:
            process=subprocess.Popen([str(node)],env={**base_env,'MONASTACK_NODE_PORT':str(port)},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            nodes.append(process)
            for _ in range(100):
                if process.poll() is not None: raise RuntimeError('node failed to start')
                try:
                    if request(len(nodes)-1,'an','GET','me')[0]==200: break
                except OSError: time.sleep(.05)
            else: raise RuntimeError('node did not start')
        def grant_same_role(_):
            return subprocess.run([str(node),'role','grant','operations','van'],env=base_env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(grant_same_role,range(2)))
        assert sum(code==0 for code in results)==1,results
        subprocess.run([str(node),'role','revoke','operations','van'],env=base_env,check=True)
        def grant_same_room(_):
            return subprocess.run([str(node),'room','grant','finance','an'],env=base_env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(grant_same_room,range(2)))
        assert sum(code==0 for code in results)==1,results
        with sqlite3.connect(db) as connection:
            assert connection.execute("SELECT COUNT(*) FROM security_audit WHERE subject='an' AND action='room_grant:finance'").fetchone()[0]==1
        subprocess.run([str(node),'room','revoke','finance','an'],env=base_env,check=True)
        room_version=request(0,'an','GET','room-admin/finance/members')[1]['version']
        competing_memberships=[{'actor':'mai','action':'grant','op':op(),'expected_version':room_version} for _ in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i:request(i,'an','POST','room-admin/finance/members',competing_memberships[i])[0],range(2)))
        assert sorted(results)==[200,409],results
        winner=results.index(200)
        assert request(1-winner,'an','POST','room-admin/finance/members',competing_memberships[winner])[0]==200
        assert request(0,'an','POST','room-admin/finance/members',{'actor':'mai','action':'revoke','op':op(),'expected_version':room_version+1})[0]==200
        collision_token=secrets.token_hex(32)
        def enroll_collision(kind):
            args=['enroll','mai'] if kind==0 else ['host-enroll','synthetic-host-000001','van','dev-agent']
            return subprocess.run([str(node),*args],env=base_env,input=collision_token,text=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(enroll_collision,range(2)))
        assert sum(code==0 for code in results)==1,results
        entry=op()
        assert request(0,'van','POST','journals',{'id':entry,'description':'Synthetic','debit':'cash','credit':'sales','minor':100,'currency':'VND','op':op()})[0]==201
        assert request(0,'an','POST',f'journals/{entry}/decision',{'action':'post','expected_version':1,'op':op()})[0]==200
        reversals=[op(),op()]
        for rid in reversals:
            assert request(0,'van','POST',f'journals/{entry}/reverse',{'id':rid,'op':op()})[0]==201
        decisions=[{'action':'post','expected_version':1,'op':op()} for _ in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i: request(i,'an','POST',f'journals/{reversals[i]}/decision',decisions[i])[0],range(2)))
        assert sorted(results)==[200,409],results
        winner=results.index(200)
        assert request(1-winner,'an','POST',f'journals/{reversals[winner]}/decision',decisions[winner])[0]==200
        expense=op()
        assert request(0,'van','POST','expenses',{'id':expense,'description':'Synthetic','minor':100,'currency':'VND','op':op()})[0]==201
        assert request(0,'an','POST',f'expenses/{expense}/decision',{'action':'approve','expected_version':1,'op':op()})[0]==200
        payments=[{'id':op(),'expense':expense,'op':op()} for _ in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i: request(i,'van','POST','payment-authorizations',payments[i])[0],range(2)))
        assert sorted(results)==[201,409],results
        chosen=results.index(201)
        assert request(1-chosen,'van','POST','payment-authorizations',payments[chosen])[0]==200
        other_currency=op()
        assert request(0,'van','POST','journals',{'id':other_currency,'description':'Synthetic','debit':'cash','credit':'sales','minor':150,'currency':'USD','op':op()})[0]==201
        assert request(1,'an','POST',f'journals/{other_currency}/decision',{'action':'post','expected_version':1,'op':op()})[0]==200
        trial=request(0,'van','GET','journals/trial-balance')[1]
        assert {g['currency']:(g['debit_total_minor'],g['credit_total_minor']) for g in trial}=={'VND':('0','0'),'USD':('150','150')}
        with sqlite3.connect(db) as conn:
            assert conn.execute("SELECT COUNT(*) FROM journal_reversals r JOIN journal_entries j ON j.id=r.reversal WHERE r.original=? AND j.state='posted'",(entry,)).fetchone()[0]==1
            assert conn.execute("SELECT COUNT(*) FROM payment_authorizations WHERE expense=? AND state IN ('pending','approved_waiting')",(expense,)).fetchone()[0]==1
            conn.execute("DELETE FROM actor_roles WHERE actor='van' AND role='accountant'")
        assert request(0,'van','POST','payment-authorizations',payments[chosen])[0]==403
        for role in ('hr','operations'):
            subprocess.run([str(node),'role','grant',role,'an'],env=base_env,check=True)
        leave=op()
        assert request(0,'van','POST','leave',{'id':leave,'start_date':'2026-11-02','end_date':'2026-11-03','reason':'Synthetic','op':op()})[0]==201
        assert request(1,'an','POST',f'leave/{leave}/decision',{'action':'approve','expected_version':1,'op':op()})[0]==200
        assert request(0,'van','POST',f'leave/{leave}/decision',{'action':'request_cancel','expected_version':2,'op':op()})[0]==200
        choices=[{'action':'cancel_approve','expected_version':3,'op':op()} for _ in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i: request(i,'an','POST',f'leave/{leave}/decision',choices[i])[0],range(2)))
        assert sorted(results)==[200,409],results
        incident=op()
        assert request(0,'van','POST','incidents',{'id':incident,'title':'Synthetic','description':'Synthetic','severity':'low','op':op()})[0]==201
        changes=[{'action':'investigate','expected_version':1,'op':op()} for _ in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i: request(i,'an','POST',f'incidents/{incident}/transition',changes[i])[0],range(2)))
        assert sorted(results)==[200,409],results
        document=op()
        assert request(0,'an','POST','documents',{'id':document,'scope':'workspace','title':'Synthetic','body':'Initial','op':op()})[0]==201
        edits=[{'title':'Synthetic','body':f'Edit {i}','expected_version':1,'op':op()} for i in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i:request(i,'an','POST',f'documents/{document}',edits[i])[0],range(2)))
        assert sorted(results)==[200,409],results
        assert request(0,'an','GET',f'documents/{document}')[1]['version']==2
        meeting=op()
        assert request(0,'an','POST','meetings',{'id':meeting,'scope':'workspace','title':'Synthetic','starts':1800000000,'ends':1800003600,'op':op()})[0]==201
        edits=[{'title':f'Edit {i}','starts':1800003600,'ends':1800007200,'expected_version':1,'op':op()} for i in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i:request(i,'an','POST',f'meetings/{meeting}',edits[i])[0],range(2)))
        assert sorted(results)==[200,409],results
        note=op()
        assert request(0,'an','POST','whiteboard/notes',{'id':note,'scope':'workspace','text':'Synthetic','x':200,'y':300,'op':op()})[0]==201
        edits=[{'text':f'Edit {i}','x':300,'y':400,'delete':False,'expected_version':1,'op':op()} for i in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i:request(i,'an','POST',f'whiteboard/notes/{note}',edits[i])[0],range(2)))
        assert sorted(results)==[200,409],results
        project,task=op(),op()
        assert request(0,'an','POST','projects',{'id':project,'name':'Synthetic','private':True,'op':op()})[0]==201
        assert request(0,'an','POST',f'projects/{project}/members',{'actor':'van','action':'grant','op':op()})[0]==200
        assert request(0,'an','POST',f'projects/{project}/tasks',{'id':task,'title':'Synthetic','assignee':None,'op':op()})[0]==201
        edits=[{'to':'in_progress','expected_version':1,'op':op()} for _ in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i:request(i,'an','POST',f'tasks/{task}/transition',edits[i])[0],range(2)))
        assert sorted(results)==[200,409],results
        # A waiting write must observe a membership revocation before it executes.
        with sqlite3.connect(db,timeout=2) as conn:
            conn.execute('BEGIN IMMEDIATE')
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending=pool.submit(request,0,'van','POST',f'tasks/{task}/transition',{'to':'done','expected_version':2,'op':op()})
                time.sleep(.15)
                assert not pending.done(), 'request did not wait for the write lock'
                conn.execute('DELETE FROM project_members WHERE project=? AND actor=?',(project,'van'))
                conn.commit()
                assert pending.result()[0]==404
            assert conn.execute('SELECT state,version FROM tasks WHERE id=?',(task,)).fetchone()==('in_progress',2)
        assert request(1,'an','POST',f'projects/{project}/members',{'actor':'van','action':'grant','op':op()})[0]==200
        job=op()
        with sqlite3.connect(db,timeout=2) as conn:
            conn.execute('BEGIN IMMEDIATE')
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending=pool.submit(request,0,'van','POST','jobs',{'id':job,'agent':'dev-agent','task':task,'instruction':'Synthetic','budget':1,'op':op()})
                time.sleep(.15)
                assert not pending.done(), 'request did not wait for the write lock'
                conn.execute('DELETE FROM project_members WHERE project=? AND actor=?',(project,'van'))
                conn.commit()
                assert pending.result()[0]==404
            assert conn.execute('SELECT COUNT(*) FROM agent_jobs WHERE id=?',(job,)).fetchone()[0]==0
        customer=op()
        assert request(0,'mai','POST','customers',{'id':customer,'name':'Synthetic','email':'','notes':'','op':op()})[0]==201
        bookings=[{'id':op(),'customer':customer,'title':'Synthetic','starts':1800000000,'ends':1800003600,'op':op()} for _ in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i:request(i,'mai','POST','bookings',bookings[i])[0],range(2)))
        assert sorted(results)==[201,409],results
        assert request(0,'mai','POST','bookings',{'id':op(),'customer':customer,'title':'Adjacent','starts':1800003600,'ends':1800007200,'op':op()})[0]==201
        booking=bookings[results.index(201)]['id']
        edits=[{'title':f'Edit {i}','starts':1799996400,'ends':1800000000,'expected_version':1,'op':op()} for i in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i:request(i,'mai','POST',f'bookings/{booking}',edits[i])[0],range(2)))
        assert sorted(results)==[200,409],results
        edits=[{'name':f'Synthetic {i}','email':'','notes':'','expected_version':1,'op':op()} for i in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i:request(i,'mai','POST',f'customers/{customer}',edits[i])[0],range(2)))
        assert sorted(results)==[200,409],results
        opportunity=op()
        assert request(0,'mai','POST','opportunities',{'id':opportunity,'customer':customer,'title':'Synthetic','op':op()})[0]==201
        edits=[{'to':'qualified','expected_version':1,'op':op()} for _ in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i:request(i,'mai','POST',f'opportunities/{opportunity}/transition',edits[i])[0],range(2)))
        assert sorted(results)==[200,409],results
        with sqlite3.connect(db,timeout=2) as conn:
            conn.execute('BEGIN IMMEDIATE')
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending=pool.submit(request,0,'mai','POST',f'opportunities/{opportunity}/transition',{'to':'proposal','expected_version':2,'op':op()})
                time.sleep(.15)
                assert not pending.done(), 'request did not wait for the write lock'
                conn.execute("DELETE FROM actor_roles WHERE actor='mai' AND role='sales'")
                conn.commit()
                assert pending.result()[0]==403
            assert conn.execute('SELECT stage,version FROM opportunities WHERE id=?',(opportunity,)).fetchone()==('qualified',2)
        chat={'id':op(),'body':'Synthetic message'}
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i:request(i,'van','POST','messages/room%3Alobby',chat)[0],range(2)))
        assert sorted(results)==[200,201],results
        session=op()
        presence={'session':session,'room':'lobby','x':2,'y':2,'seq':1}
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda i:request(i,'van','POST','presence',presence)[0],range(2)))
        assert sorted(results)==[204,409],results
        private_message=op()
        with sqlite3.connect(db,timeout=2) as conn:
            conn.execute('BEGIN IMMEDIATE')
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending=pool.submit(request,0,'van','POST','messages/room%3Afinance',{'id':private_message,'body':'Synthetic private message'})
                time.sleep(.15)
                assert not pending.done(), 'request did not wait for the write lock'
                conn.execute("DELETE FROM room_members WHERE room='finance' AND actor='van'")
                conn.commit()
                assert pending.result()[0]==403
            assert conn.execute('SELECT COUNT(*) FROM messages WHERE id=?',(private_message,)).fetchone()[0]==0
        # Hold the writer lock while a request waits; revoke its credential before it can authenticate.
        blocked_leave=op()
        with sqlite3.connect(db,timeout=2) as conn:
            conn.execute('BEGIN IMMEDIATE')
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending=pool.submit(request,0,'van','POST','leave',{'id':blocked_leave,'start_date':'2026-12-01','end_date':'2026-12-02','reason':'Synthetic','op':op()})
                time.sleep(.15)
                assert not pending.done(), 'request did not wait for the write lock'
                conn.execute('DELETE FROM tokens WHERE hash=?',(hashlib.sha256(tokens['van'].encode()).digest(),))
                conn.commit()
                assert pending.result()[0]==401
            assert conn.execute('SELECT COUNT(*) FROM leave_requests WHERE id=?',(blocked_leave,)).fetchone()[0]==0
        room_version=request(0,'an','GET','room-admin/finance/members')[1]['version']
        blocked_op=op()
        with sqlite3.connect(db,timeout=2) as conn:
            conn.execute('BEGIN IMMEDIATE')
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending=pool.submit(request,0,'an','POST','room-admin/finance/members',{'actor':'mai','action':'grant','op':blocked_op,'expected_version':room_version})
                time.sleep(.15)
                assert not pending.done(), 'request did not wait for the write lock'
                conn.execute("DELETE FROM actor_roles WHERE actor='an' AND role='org-admin'")
                conn.commit()
                assert pending.result()[0]==403
            assert conn.execute('SELECT COUNT(*) FROM room_membership_ops WHERE op=?',(blocked_op,)).fetchone()[0]==0
        print('Two-node writes: finance, HR, incidents, documents, meetings, whiteboard, tasks, sales, chat, presence and revocation passed')
    finally:
        for process in nodes:
            if process.poll() is None: process.terminate()
        for process in nodes: process.wait(timeout=5)
