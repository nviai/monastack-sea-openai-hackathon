"""Local two-client HTTP integration; uses a temporary isolated database."""
import json
import concurrent.futures
import hashlib
import os
import secrets
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from realtime_client import Realtime, ticket

binary = Path(__file__).resolve().parents[1] / 'target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack-test-') as directory:
    db = Path(directory) / 'office.sqlite3'
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env = {**os.environ, 'MONASTACK_DB': str(db)}
    env['MONASTACK_NODE_PORT'] = str(port)
    tokens = {name: secrets.token_hex(32) for name in ('an', 'van', 'mai')}
    for name, token in tokens.items():
        subprocess.run([str(binary), 'enroll', name], env=env, input=token, text=True, check=True)
    host_ids={'host1':'synthetic-host-00000001','host2':'synthetic-host-00000002'}
    for alias,sponsor in (('host1','an'),('host2','van')):
        tokens[alias]=secrets.token_hex(32)
        subprocess.run([str(binary),'host-enroll',host_ids[alias],sponsor,'dev-agent'],env=env,input=tokens[alias],text=True,check=True)
    assert subprocess.run([str(binary),'host-enroll','collision-host-00000001','an','dev-agent'],env=env,input=tokens['an'],text=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode != 0
    assert subprocess.run([str(binary),'enroll','an'],env=env,input=tokens['host1'],text=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode != 0
    # Startup must not mutate an unrelated database or a future schema.
    foreign = Path(directory) / 'unrelated.sqlite3'
    with sqlite3.connect(foreign) as conn:
        conn.execute('CREATE TABLE personal_data(value TEXT)')
        conn.execute("INSERT INTO personal_data VALUES ('preserve')")
    before = hashlib.sha256(foreign.read_bytes()).digest()
    refused = subprocess.run([str(binary)], env={**env,'MONASTACK_DB':str(foreign)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    assert refused.returncode != 0 and hashlib.sha256(foreign.read_bytes()).digest() == before
    newer = Path(directory) / 'newer.sqlite3'
    with sqlite3.connect(newer) as conn:
        conn.execute('PRAGMA user_version=99')
    before = hashlib.sha256(newer.read_bytes()).digest()
    refused = subprocess.run([str(binary)], env={**env,'MONASTACK_DB':str(newer)}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    assert refused.returncode != 0 and hashlib.sha256(newer.read_bytes()).digest() == before
    process = None
    def start():
        global process
        process = subprocess.Popen([str(binary)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            if process.poll() is not None:
                raise RuntimeError('node failed to start; the selected port may be in use')
            try:
                urllib.request.urlopen(f'http://127.0.0.1:{port}/v1/me', timeout=.2)
            except urllib.error.HTTPError:
                return
            except OSError:
                time.sleep(.05)
        raise RuntimeError('node did not start')
    def stop():
        process.terminate()
        process.wait(timeout=5)
    def request(actor, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(f'http://127.0.0.1:{port}/v1/'+path, data=data, method=method,
            headers={'Authorization':'Bearer '+tokens[actor], 'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=2) as result:
                raw=result.read()
                return result.status, json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            return e.code, None
    try:
        start()
        principal=request('an','GET','me')[1]
        assert principal['actor']=='an'
        authority_id=principal['authority_id']
        assert len(authority_id)==36
        project = secrets.token_hex(16)
        task = secrets.token_hex(16)
        project_cmd = {'id':project,'name':'Test project','op':secrets.token_hex(16)}
        assert request('an','POST','projects',project_cmd)[0]==201
        assert request('an','POST','projects',project_cmd)[0]==200
        task_cmd = {'id':task,'title':'Test task','assignee':'dev-agent','op':secrets.token_hex(16)}
        assert request('an','POST',f'projects/{project}/tasks',task_cmd)[0]==201
        assert request('van','GET',f'projects/{project}/tasks')[1][0]['assignee']=='dev-agent'
        transition = {'to':'in_progress','expected_version':1,'op':secrets.token_hex(16)}
        assert request('van','POST',f'tasks/{task}/transition',transition)[0]==200
        assert request('van','POST',f'tasks/{task}/transition',transition)[0]==200
        assert request('an','POST',f'tasks/{task}/transition',{'to':'done','expected_version':1,'op':secrets.token_hex(16)})[0]==409
        assert request('an','POST',f'tasks/{task}/transition',{'to':'todo','expected_version':2,'op':transition['op']})[0]==409
        assignment = {'assignee':'van','expected_version':2,'op':secrets.token_hex(16)}
        assert request('an','POST',f'tasks/{task}/assign',assignment)[0]==200
        assert request('an','POST',f'tasks/{task}/assign',assignment)[0]==200
        assert request('van','POST',f'tasks/{task}/assign',{'assignee':'missing','expected_version':3,'op':secrets.token_hex(16)})[0]==400
        comment={'id':secrets.token_hex(16),'body':'Test comment','op':secrets.token_hex(16)}
        assert request('an','POST',f'tasks/{task}/comments',comment)[0]==201
        assert request('an','POST',f'tasks/{task}/comments',comment)[0]==200
        assert len(request('van','GET',f'tasks/{task}/comments')[1])==1
        history = request('van','GET',f'tasks/{task}/history')[1]
        assert [event['action'] for event in history]==['created','transition:todo:in_progress','assignment:dev-agent:van','comment_added']
        job=secrets.token_hex(16)
        proposal={'id':job,'agent':'dev-agent','task':task,'instruction':'Test proposal','budget':5,'op':secrets.token_hex(16)}
        assert request('van','POST','jobs',proposal)[0]==201
        assert request('van','POST','jobs',proposal)[0]==200
        assert request('van','POST',f'jobs/{job}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})[0]==403
        approval={'action':'approve','expected_version':1,'op':secrets.token_hex(16)}
        assert request('an','POST',f'jobs/{job}/decision',approval)[0]==200
        assert request('an','POST',f'jobs/{job}/decision',approval)[0]==200
        assert request('van','GET','jobs')[1][0]['state']=='approved_waiting'
        assert request('van','POST',f'jobs/{job}/decision',{'action':'cancel','expected_version':2,'op':secrets.token_hex(16)})[0]==200
        assert request('an','GET','jobs')[1][0]['state']=='cancelled'
        assert [e['action'] for e in request('an','GET',f'jobs/{job}/history')[1]]==['proposed','approve','cancel'] 
        assert request('host1','GET','host/jobs')[0]==403
        assert request('an','GET','host/jobs')[0]==401
        assert request('host1','GET','me')[0]==401
        subprocess.run([str(binary),'host-claims','enable'],env=env,check=True)
        host_job=secrets.token_hex(16)
        assert request('van','POST','jobs',{'id':host_job,'agent':'dev-agent','task':None,'instruction':'Synthetic host report','budget':5,'op':secrets.token_hex(16)})[0]==201
        assert request('an','POST',f'jobs/{host_job}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})[0]==200
        assert any(j['id']==host_job for j in request('host1','GET','host/jobs')[1])
        claim=request('host1','POST','host/claim',{'job':host_job})
        assert claim[0]==200 and claim[1]['instruction']=='Synthetic host report'
        assert request('host1','POST','host/claim',{'job':host_job})[1]['fence']==claim[1]['fence']
        assert request('host2','POST','host/claim',{'job':host_job})[0]==409
        assert request('host2','GET',f'host/jobs/{host_job}/control')[0]==404
        assert request('host1','GET',f'host/jobs/{host_job}/control')[1]['active'] is True
        report={'fence':claim[1]['fence'],'outcome':'success','summary':'Synthetic report only','op':secrets.token_hex(16)}
        assert request('host1','POST',f'host/jobs/{host_job}/report',dict(report,fence=secrets.token_hex(16)))[0]==409
        subprocess.run([str(binary),'host-claims','disable'],env=env,check=True)
        assert request('host1','GET',f'host/jobs/{host_job}/control')[1]['active'] is False
        assert request('host1','POST',f'host/jobs/{host_job}/report',report)[0]==403
        subprocess.run([str(binary),'host-claims','enable'],env=env,check=True)
        assert request('host1','GET',f'host/jobs/{host_job}/control')[1]['active'] is False
        assert request('host1','POST',f'host/jobs/{host_job}/report',report)[0]==409
        assert request('host1','POST','host/claim',{'job':host_job})[0]==409
        assert request('van','POST',f'jobs/{host_job}/decision',{'action':'cancel','expected_version':3,'op':secrets.token_hex(16)})[0]==200
        report_job=secrets.token_hex(16)
        assert request('van','POST','jobs',{'id':report_job,'agent':'dev-agent','task':None,'instruction':'Synthetic reported job','budget':5,'op':secrets.token_hex(16)})[0]==201
        assert request('an','POST',f'jobs/{report_job}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})[0]==200
        report_claim=request('host1','POST','host/claim',{'job':report_job})[1]
        report={'fence':report_claim['fence'],'outcome':'success','summary':'Synthetic report only','op':secrets.token_hex(16)}
        assert request('host1','POST',f'host/jobs/{report_job}/report',report)[0]==200
        assert request('host1','POST',f'host/jobs/{report_job}/report',report)[0]==200
        assert request('host1','POST',f'host/jobs/{report_job}/report',dict(report,summary='changed'))[0]==409
        reported=next(j for j in request('van','GET','jobs')[1] if j['id']==report_job)
        assert reported['state']=='host_reported' and reported['report_summary']=='Synthetic report only'
        race_job=secrets.token_hex(16)
        assert request('van','POST','jobs',{'id':race_job,'agent':'dev-agent','task':None,'instruction':'Synthetic lease race','budget':5,'op':secrets.token_hex(16)})[0]==201
        assert request('an','POST',f'jobs/{race_job}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})[0]==200
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            a=pool.submit(request,'host1','POST','host/claim',{'job':race_job})
            b=pool.submit(request,'host2','POST','host/claim',{'job':race_job})
            a_status,b_status=a.result()[0],b.result()[0]
        assert sorted([a_status,b_status])==[200,409]
        assert request('van','POST',f'jobs/{race_job}/decision',{'action':'cancel','expected_version':3,'op':secrets.token_hex(16)})[0]==200
        subprocess.run([str(binary),'host-revoke',host_ids['host1']],env=env,check=True)
        assert request('host1','GET','host/jobs')[0]==401
        cancelled_job=secrets.token_hex(16)
        assert request('van','POST','jobs',{'id':cancelled_job,'agent':'dev-agent','task':None,'instruction':'Synthetic cancellation','budget':5,'op':secrets.token_hex(16)})[0]==201
        assert request('an','POST',f'jobs/{cancelled_job}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})[0]==200
        cancelled_claim=request('host2','POST','host/claim',{'job':cancelled_job})[1]
        assert request('van','POST',f'jobs/{cancelled_job}/decision',{'action':'cancel','expected_version':3,'op':secrets.token_hex(16)})[0]==200
        assert request('host2','GET',f'host/jobs/{cancelled_job}/control')[1]['active'] is False
        assert request('host2','POST',f'host/jobs/{cancelled_job}/report',{'fence':cancelled_claim['fence'],'outcome':'success','summary':'must fail','op':secrets.token_hex(16)})[0]==409
        expired_job=secrets.token_hex(16)
        assert request('van','POST','jobs',{'id':expired_job,'agent':'dev-agent','task':None,'instruction':'Synthetic expiry','budget':5,'op':secrets.token_hex(16)})[0]==201
        assert request('an','POST',f'jobs/{expired_job}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})[0]==200
        expired_claim=request('host2','POST','host/claim',{'job':expired_job})[1]
        with sqlite3.connect(db) as conn:
            conn.execute('UPDATE host_claims SET deadline=0 WHERE job=?',(expired_job,))
        assert request('host2','GET',f'host/jobs/{expired_job}/control')[1]['active'] is False
        assert request('host2','POST','host/claim',{'job':expired_job})[0]==409
        assert request('host2','POST',f'host/jobs/{expired_job}/report',{'fence':expired_claim['fence'],'outcome':'success','summary':'must fail','op':secrets.token_hex(16)})[0]==409
        assert request('van','POST',f'jobs/{expired_job}/decision',{'action':'cancel','expected_version':3,'op':secrets.token_hex(16)})[0]==200
        incident=secrets.token_hex(16)
        report={'id':incident,'title':'Synthetic incident','description':'Example only','severity':'high','op':secrets.token_hex(16)}
        assert request('van','POST','incidents',report)[0]==201
        assert request('van','POST','incidents',report)[0]==200
        assert request('van','POST','incidents',dict(report,title='changed'))[0]==409
        assert len(request('van','GET','incidents')[1])==1
        assert request('an','GET','incidents')[1]==[]
        assert request('an','GET',f'incidents/{incident}/history')[0]==404
        comment={'id':secrets.token_hex(16),'op':secrets.token_hex(16),'body':'Synthetic reporter update'}
        assert request('an','GET',f'incidents/{incident}/comments')[0]==404
        assert request('an','POST',f'incidents/{incident}/comments',comment)[0]==404
        assert request('van','POST',f'incidents/{incident}/comments',comment)[0]==201
        assert request('van','POST',f'incidents/{incident}/comments',comment)[0]==200
        assert request('van','POST',f'incidents/{incident}/comments',dict(comment,body='changed'))[0]==409
        assert request('van','POST',f'incidents/{incident}/comments',dict(comment,op=secrets.token_hex(16)))[0]==409
        assert request('van','POST',f'incidents/{incident}/comments',dict(comment,id=secrets.token_hex(16),op=secrets.token_hex(16),body=' '))[0]==400
        assert request('van','POST',f'incidents/{incident}/comments',dict(comment,id=secrets.token_hex(16),op=secrets.token_hex(16),body='a'*2001))[0]==400
        assert len(request('van','GET',f'incidents/{incident}/comments')[1])==1
        change={'action':'investigate','expected_version':1,'op':secrets.token_hex(16)}
        assert request('an','POST',f'incidents/{incident}/transition',change)[0]==403
        assert request('van','POST','incidents',dict(report,id=secrets.token_hex(16),op=secrets.token_hex(16),severity='unknown'))[0]==400
        for name in ('an','van'):
            subprocess.run([str(binary),'role','grant','operations',name],env=env,check=True)
        assert subprocess.run([str(binary),'role','grant','operations','an'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode != 0
        assert subprocess.run([str(binary),'role','grant','operations','missing'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode != 0
        assert request('van','POST',f'incidents/{incident}/transition',change)[0]==403
        assert len(request('an','GET','incidents')[1])==1
        response={'id':secrets.token_hex(16),'op':secrets.token_hex(16),'body':'Synthetic responder update'}
        assert request('an','POST',f'incidents/{incident}/comments',response)[0]==201
        assert [c['body'] for c in request('van','GET',f'incidents/{incident}/comments')[1]]==['Synthetic reporter update','Synthetic responder update']
        assert request('an','POST',f'incidents/{incident}/transition',dict(change,action='resolve'))[0]==409
        assert request('an','POST',f'incidents/{incident}/transition',change)[0]==200
        assert request('an','POST',f'incidents/{incident}/transition',change)[0]==200
        assert request('an','POST',f'incidents/{incident}/transition',{'action':'resolve','expected_version':1,'op':secrets.token_hex(16)})[0]==409
        resolution={'action':'resolve','expected_version':2,'op':secrets.token_hex(16)}
        assert request('an','POST',f'incidents/{incident}/transition',resolution)[0]==200
        assert [e['action'] for e in request('van','GET',f'incidents/{incident}/history')[1]]==['reported','commented','commented','investigate','resolve']
        for name in ('an','van'):
            subprocess.run([str(binary),'role','revoke','operations',name],env=env,check=True)
        assert request('an','GET','incidents')[1]==[]
        assert request('an','GET',f'incidents/{incident}/comments')[0]==404
        assert request('an','POST',f'incidents/{incident}/comments',response)[0]==404
        assert request('an','POST',f'incidents/{incident}/transition',resolution)[0]==403
        leave_id=secrets.token_hex(16)
        leave_cmd={'id':leave_id,'start_date':'2026-10-31','end_date':'2026-11-03','reason':'Test request','op':secrets.token_hex(16)}
        assert request('van','POST','leave',leave_cmd)[0]==201
        assert request('van','POST','leave',leave_cmd)[0]==200
        assert len(request('van','GET','leave')[1])==1
        assert request('van','GET','leave/calendar?month=2026-11')[1]['items']==[]
        assert request('van','GET','leave/calendar?month=2026-13')[0]==400
        assert request('an','GET','leave')[1]==[]
        assert request('an','GET',f'leave/{leave_id}/history')[0]==404
        assert [e['action'] for e in request('van','GET',f'leave/{leave_id}/history')[1]]==['proposed']
        assert request('mai','GET','leave')[1]==[]
        leave_decision={'action':'approve','expected_version':1,'op':secrets.token_hex(16)}
        assert request('an','POST',f'leave/{leave_id}/decision',leave_decision)[0]==403
        assert request('van','POST','leave',{'id':secrets.token_hex(16),'start_date':'2026-02-30','end_date':'2026-03-01','reason':'bad','op':secrets.token_hex(16)})[0]==400
        # An explicit test-only HR grant; the actual seed has no HR members.
        subprocess.run([str(binary),'role','grant','hr','an'],env=env,check=True)
        assert len(request('an','GET','leave')[1])==1
        assert request('an','POST',f'leave/{leave_id}/decision',leave_decision)[0]==200
        assert request('an','POST',f'leave/{leave_id}/decision',leave_decision)[0]==200
        calendar=request('an','GET','leave/calendar?month=2026-11')[1]
        assert len(calendar['items'])==1 and calendar['items'][0]['id']==leave_id
        assert 'reason' not in calendar['items'][0] and not calendar['truncated']
        assert request('mai','GET','leave/calendar?month=2026-11')[1]['items']==[]
        assert request('van','GET','leave/calendar?month=2026-10')[1]['items'][0]['id']==leave_id
        assert request('van','GET','leave/calendar?month=2026-12')[1]['items']==[]
        assert [e['action'] for e in request('an','GET',f'leave/{leave_id}/history')[1]]==['proposed','approve']
        cancel={'action':'request_cancel','expected_version':2,'op':secrets.token_hex(16)}
        assert request('an','POST',f'leave/{leave_id}/decision',cancel)[0]==404
        assert request('van','POST',f'leave/{leave_id}/decision',cancel)[0]==200
        assert request('van','POST',f'leave/{leave_id}/decision',cancel)[0]==200
        assert request('van','GET','leave/calendar?month=2026-11')[1]['items'][0]['state']=='cancellation_pending'
        assert request('an','POST',f'leave/{leave_id}/decision',{'action':'cancel_reject','expected_version':2,'op':secrets.token_hex(16)})[0]==409
        rejection_candidates=[{'action':'cancel_reject','expected_version':3,'op':secrets.token_hex(16)} for _ in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            statuses=list(pool.map(lambda candidate: request('an','POST',f'leave/{leave_id}/decision',candidate)[0], rejection_candidates))
        assert sorted(statuses)==[200,409]
        assert request('an','POST',f'leave/{leave_id}/decision',rejection_candidates[statuses.index(200)])[0]==200
        assert request('van','POST',f'leave/{leave_id}/decision',{'action':'request_cancel','expected_version':4,'op':secrets.token_hex(16)})[0]==200
        assert request('van','POST',f'leave/{leave_id}/decision',{'action':'cancel_withdraw','expected_version':5,'op':secrets.token_hex(16)})[0]==200
        assert request('van','POST',f'leave/{leave_id}/decision',{'action':'request_cancel','expected_version':6,'op':secrets.token_hex(16)})[0]==200
        cancel_decision={'action':'cancel_approve','expected_version':7,'op':secrets.token_hex(16)}
        subprocess.run([str(binary),'role','grant','hr','van'],env=env,check=True)
        assert request('van','POST',f'leave/{leave_id}/decision',cancel_decision)[0]==403
        subprocess.run([str(binary),'role','revoke','hr','van'],env=env,check=True)
        assert request('an','POST',f'leave/{leave_id}/decision',cancel_decision)[0]==200
        assert request('an','POST',f'leave/{leave_id}/decision',cancel_decision)[0]==200
        assert request('van','GET','leave')[1][0]['state']=='cancelled'
        assert request('van','GET','leave/calendar?month=2026-11')[1]['items']==[]
        own_leave=secrets.token_hex(16)
        assert request('an','POST','leave',{'id':own_leave,'start_date':'2026-11-02','end_date':'2026-11-03','reason':'Own request','op':secrets.token_hex(16)})[0]==201
        assert request('an','POST',f'leave/{own_leave}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})[0]==403
        subprocess.run([str(binary),'role','revoke','hr','an'],env=env,check=True)
        assert request('an','GET','leave/calendar?month=2026-11')[1]['items']==[]
        assert request('an','POST',f'leave/{leave_id}/decision',cancel_decision)[0]==403
        assert len(request('an','GET','leave')[1])==1
        pending=secrets.token_hex(16)
        assert request('van','POST','leave',{'id':pending,'start_date':'2026-11-04','end_date':'2026-11-05','reason':'Withdraw test','op':secrets.token_hex(16)})[0]==201
        withdrawal={'action':'withdraw','expected_version':1,'op':secrets.token_hex(16)}
        assert request('an','POST',f'leave/{pending}/decision',withdrawal)[0]==404
        assert request('van','POST',f'leave/{pending}/decision',dict(withdrawal,expected_version=2))[0]==409
        assert request('van','POST',f'leave/{pending}/decision',withdrawal)[0]==200
        assert request('van','POST',f'leave/{pending}/decision',withdrawal)[0]==200
        assert request('van','POST',f'leave/{leave_id}/decision',{'action':'withdraw','expected_version':2,'op':secrets.token_hex(16)})[0]==409
        assert [e['action'] for e in request('van','GET',f'leave/{pending}/history')[1]]==['proposed','withdraw']
        expense=secrets.token_hex(16)
        expense_cmd={'id':expense,'description':'Test expense','minor':500,'currency':'VND','op':secrets.token_hex(16)}
        assert request('mai','GET','expenses')[0]==403
        assert request('mai','POST','expenses',expense_cmd)[0]==403
        assert request('van','POST','expenses',expense_cmd)[0]==201
        assert request('van','POST','expenses',expense_cmd)[0]==200
        assert request('van','POST',f'expenses/{expense}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})[0]==403
        decision={'action':'approve','expected_version':1,'op':secrets.token_hex(16)}
        assert request('an','POST',f'expenses/{expense}/decision',decision)[0]==200
        assert request('an','POST',f'expenses/{expense}/decision',decision)[0]==200
        assert [e['action'] for e in request('van','GET',f'expenses/{expense}/history')[1]]==['proposed','approve']
        assert request('mai','GET',f'expenses/{expense}/history')[0]==403
        assert request('an','POST',f'expenses/{expense}/decision',{'action':'reject','expected_version':1,'op':secrets.token_hex(16)})[0]==409
        self_id=secrets.token_hex(16)
        assert request('an','POST','expenses',{'id':self_id,'description':'Own expense','minor':100,'currency':'VND','op':secrets.token_hex(16)})[0]==201
        assert request('an','POST',f'expenses/{self_id}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})[0]==403
        withdrawal_expense={'action':'withdraw','expected_version':1,'op':secrets.token_hex(16)}
        assert request('van','POST',f'expenses/{self_id}/decision',withdrawal_expense)[0]==403
        assert request('an','POST',f'expenses/{self_id}/decision',dict(withdrawal_expense,expected_version=2))[0]==409
        assert request('an','POST',f'expenses/{self_id}/decision',withdrawal_expense)[0]==200
        assert request('an','POST',f'expenses/{self_id}/decision',withdrawal_expense)[0]==200
        assert request('van','POST',f'expenses/{expense}/decision',{'action':'withdraw','expected_version':2,'op':secrets.token_hex(16)})[0]==409
        payment=secrets.token_hex(16)
        payment_cmd={'id':payment,'expense':expense,'op':secrets.token_hex(16)}
        assert request('mai','GET','payment-authorizations')[0]==403
        assert request('van','POST','payment-authorizations',dict(payment_cmd,expense=self_id))[0]==409
        competing={'id':secrets.token_hex(16),'expense':expense,'op':secrets.token_hex(16)}
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            a=pool.submit(request,'van','POST','payment-authorizations',payment_cmd)
            b=pool.submit(request,'van','POST','payment-authorizations',competing)
            first_status,second_status=a.result()[0],b.result()[0]
        assert sorted([first_status,second_status])==[201,409]
        if second_status==201:
            payment_cmd=competing
            payment=competing['id']
        assert request('van','POST','payment-authorizations',payment_cmd)[0]==200
        assert request('van','POST','payment-authorizations',dict(payment_cmd,id=secrets.token_hex(16),op=secrets.token_hex(16)))[0]==409
        payment_approval={'action':'approve','expected_version':1,'op':secrets.token_hex(16)}
        assert request('van','POST',f'payment-authorizations/{payment}/decision',payment_approval)[0]==403
        assert request('an','POST',f'payment-authorizations/{payment}/decision',payment_approval)[0]==200
        assert request('an','POST',f'payment-authorizations/{payment}/decision',payment_approval)[0]==200
        assert request('van','GET','payment-authorizations')[1][0]['state']=='approved_waiting'
        assert request('van','POST','payment-authorizations',dict(payment_cmd,id=secrets.token_hex(16),op=secrets.token_hex(16)))[0]==409
        assert [e['action'] for e in request('an','GET',f'payment-authorizations/{payment}/history')[1]]==['requested','approve']
        revoke_payment={'action':'revoke','expected_version':2,'op':secrets.token_hex(16)}
        assert request('van','POST',f'payment-authorizations/{payment}/decision',revoke_payment)[0]==403
        assert request('an','POST',f'payment-authorizations/{payment}/decision',dict(revoke_payment,expected_version=1))[0]==409
        assert request('an','POST',f'payment-authorizations/{payment}/decision',revoke_payment)[0]==200
        assert request('an','POST',f'payment-authorizations/{payment}/decision',revoke_payment)[0]==200
        assert next(x for x in request('van','GET','payment-authorizations')[1] if x['id']==payment)['state']=='revoked'
        replacement={'id':secrets.token_hex(16),'expense':expense,'op':secrets.token_hex(16)}
        assert request('van','POST','payment-authorizations',replacement)[0]==201
        journal=secrets.token_hex(16)
        journal_cmd={'id':journal,'description':'Synthetic journal','debit':'cash','credit':'revenue','minor':100,'currency':'VND','op':secrets.token_hex(16)}
        assert request('mai','GET','journals')[0]==403
        assert request('van','POST','journals',dict(journal_cmd,credit='cash'))[0]==400
        assert request('van','POST','journals',journal_cmd)[0]==201
        assert request('van','POST','journals',journal_cmd)[0]==200
        assert request('mai','GET','journals/trial-balance')[0]==403
        assert request('van','GET','journals/trial-balance')[1]==[]
        journal_post={'action':'post','expected_version':1,'op':secrets.token_hex(16)}
        assert request('van','POST',f'journals/{journal}/decision',journal_post)[0]==403
        assert request('an','POST',f'journals/{journal}/decision',journal_post)[0]==200
        assert request('an','POST',f'journals/{journal}/decision',journal_post)[0]==200
        assert request('van','POST',f'journals/{journal}/decision',{'action':'withdraw','expected_version':2,'op':secrets.token_hex(16)})[0]==409
        assert request('van','GET','journals')[1][0]['state']=='posted'
        assert [e['action'] for e in request('van','GET',f'journals/{journal}/history')[1]]==['proposed','post']
        balances=request('van','GET','journals/balances')[1]
        assert {(b['account'],b['net_debit_minor']) for b in balances}=={('cash','100'),('revenue','-100')}
        trial=request('van','GET','journals/trial-balance')[1]
        assert len(trial)==1 and trial[0]['currency']=='VND'
        assert trial[0]['debit_total_minor']=='100' and trial[0]['credit_total_minor']=='100'
        assert {(a['account'],a['debit_minor'],a['credit_minor']) for a in trial[0]['accounts']}=={('cash','100','0'),('revenue','0','100')}
        reversal=secrets.token_hex(16)
        reversal_cmd={'id':reversal,'op':secrets.token_hex(16)}
        assert request('van','POST',f'journals/{journal}/reverse',reversal_cmd)[0]==201
        assert request('van','POST',f'journals/{journal}/reverse',reversal_cmd)[0]==200
        other_reversal=secrets.token_hex(16)
        assert request('van','POST',f'journals/{journal}/reverse',{'id':other_reversal,'op':secrets.token_hex(16)})[0]==201
        reverse_post={'action':'post','expected_version':1,'op':secrets.token_hex(16)}
        assert request('van','POST',f'journals/{reversal}/decision',reverse_post)[0]==403
        other_post={'action':'post','expected_version':1,'op':secrets.token_hex(16)}
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            first=pool.submit(request,'an','POST',f'journals/{reversal}/decision',reverse_post)
            second=pool.submit(request,'an','POST',f'journals/{other_reversal}/decision',other_post)
            first_status,second_status=first.result()[0],second.result()[0]
        assert sorted([first_status,second_status])==[200,409]
        chosen,chosen_op=(reversal,reverse_post) if first_status==200 else (other_reversal,other_post)
        assert request('an','POST',f'journals/{chosen}/decision',chosen_op)[0]==200
        assert request('van','POST',f'journals/{journal}/reverse',{'id':secrets.token_hex(16),'op':secrets.token_hex(16)})[0]==409
        assert all(b['net_debit_minor']=='0' for b in request('van','GET','journals/balances')[1])
        trial=request('van','GET','journals/trial-balance')[1]
        assert trial[0]['debit_total_minor']=='0' and trial[0]['credit_total_minor']=='0'
        assert request('van','POST','expenses',{'id':secrets.token_hex(16),'description':'bad','minor':-1,'currency':'VND','op':secrets.token_hex(16)})[0]==400
        # Retrying an already accepted decision must still check current authority.
        with sqlite3.connect(db) as conn:
            had_accountant = conn.execute("SELECT EXISTS(SELECT 1 FROM actor_roles WHERE actor='an' AND role='accountant')").fetchone()[0]
            conn.execute("INSERT OR IGNORE INTO actor_roles(actor,role) VALUES ('an','accountant')")
            conn.execute("DELETE FROM actor_roles WHERE actor='an' AND role='org-admin'")
        assert request('an','POST',f'expenses/{expense}/decision',decision)[0]==403
        assert request('an','POST',f'jobs/{job}/decision',approval)[0]==403
        assert request('an','POST',f'journals/{journal}/decision',journal_post)[0]==403
        assert request('an','POST',f'payment-authorizations/{payment}/decision',payment_approval)[0]==403
        with sqlite3.connect(db) as conn:
            conn.execute("INSERT INTO actor_roles(actor,role) VALUES ('an','org-admin')")
            if not had_accountant:
                conn.execute("DELETE FROM actor_roles WHERE actor='an' AND role='accountant'")
        customer=secrets.token_hex(16)
        customer_cmd={'id':customer,'name':'Test customer','email':'demo@example.invalid','notes':'Test data','op':secrets.token_hex(16)}
        assert request('van','GET','customers')[0]==403
        assert request('van','POST','customers',customer_cmd)[0]==403
        assert request('mai','POST','customers',customer_cmd)[0]==201
        assert request('mai','POST','customers',customer_cmd)[0]==200
        assert len(request('an','GET','customers')[1])==1
        assert request('van','GET',f'customers/{customer}')[0]==403
        customer_update={'name':'Test customer','email':'demo@example.invalid','notes':'Updated','expected_version':1,'op':secrets.token_hex(16)}
        assert request('mai','POST',f'customers/{customer}',customer_update)[0]==200
        assert request('mai','POST',f'customers/{customer}',customer_update)[0]==200
        assert request('an','POST',f'customers/{customer}',{'name':'Old','email':'','notes':'','expected_version':1,'op':secrets.token_hex(16)})[0]==409
        opportunity=secrets.token_hex(16)
        opportunity_cmd={'id':opportunity,'customer':customer,'title':'Synthetic opportunity','op':secrets.token_hex(16)}
        assert request('van','GET','opportunities')[0]==403
        assert request('van','GET','sales/capabilities')[0]==403
        assert request('van','POST','opportunities',opportunity_cmd)[0]==403
        assert request('mai','POST','opportunities',opportunity_cmd)[0]==201
        assert request('mai','POST','opportunities',opportunity_cmd)[0]==200
        assert request('mai','POST','opportunities',dict(opportunity_cmd,title='changed'))[0]==409
        assert request('an','GET','opportunities')[1][0]['customer_name']=='Test customer'
        with sqlite3.connect(db) as conn:
            conn.execute("INSERT INTO actor_roles(actor,role) VALUES ('van','cs')")
        assert len(request('van','GET','opportunities')[1])==1
        assert request('van','GET','sales/capabilities')[1]['can_manage'] is False
        assert request('mai','GET','sales/capabilities')[1]['can_manage'] is True
        booking=secrets.token_hex(16)
        booking_cmd={'id':booking,'customer':customer,'title':'Synthetic appointment','starts':1800000000,'ends':1800003600,'op':secrets.token_hex(16)}
        assert request('van','GET','bookings/capabilities')[1]['can_manage'] is False
        assert request('van','POST','bookings',booking_cmd)[0]==403
        assert request('mai','POST','bookings',dict(booking_cmd,ends=1800000000))[0]==400
        competing_booking=dict(booking_cmd,id=secrets.token_hex(16),op=secrets.token_hex(16))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            statuses=list(pool.map(lambda cmd:request('mai','POST','bookings',cmd)[0],[booking_cmd,competing_booking]))
        assert sorted(statuses)==[201,409]
        if statuses[1]==201: booking_cmd,booking=competing_booking,competing_booking['id']
        assert request('mai','POST','bookings',booking_cmd)[0]==200
        assert request('mai','POST','bookings',dict(booking_cmd,title='changed'))[0]==409
        assert len(request('van','GET','bookings')[1])==1
        adjacent_booking={'id':secrets.token_hex(16),'customer':customer,'title':'Adjacent','starts':1800003600,'ends':1800007200,'op':secrets.token_hex(16)}
        assert request('mai','POST','bookings',adjacent_booking)[0]==201
        reschedule_booking={'title':'Rescheduled','starts':1799996400,'ends':1800000000,'expected_version':1,'op':secrets.token_hex(16)}
        assert request('van','POST',f'bookings/{booking}',reschedule_booking)[0]==403
        assert request('mai','POST',f'bookings/{booking}',dict(reschedule_booking,starts=1800003600,ends=1800007200))[0]==409
        assert request('mai','POST',f'bookings/{booking}',reschedule_booking)[0]==200
        assert request('mai','POST',f'bookings/{booking}',reschedule_booking)[0]==200
        assert request('mai','POST',f'bookings/{booking}',dict(reschedule_booking,op=secrets.token_hex(16)))[0]==409
        booking_cancel={'expected_version':2,'op':secrets.token_hex(16)}
        assert request('van','POST',f'bookings/{booking}/cancel',booking_cancel)[0]==403
        assert request('mai','POST',f'bookings/{booking}/cancel',dict(booking_cancel,expected_version=1))[0]==409
        assert request('mai','POST',f'bookings/{booking}/cancel',booking_cancel)[0]==200
        assert request('mai','POST',f'bookings/{booking}/cancel',booking_cancel)[0]==200
        assert [e['action'] for e in request('van','GET',f'bookings/{booking}/history')[1]]==['scheduled','rescheduled','cancelled']
        replacement_booking=dict(booking_cmd,id=secrets.token_hex(16),op=secrets.token_hex(16))
        assert request('mai','POST','bookings',replacement_booking)[0]==201
        contract=secrets.token_hex(16)
        contract_cmd={'id':contract,'customer':customer,'title':'Synthetic agreement','terms':'Example internal terms','op':secrets.token_hex(16)}
        assert request('van','GET','contracts')[0]==403
        assert request('van','POST','contracts',contract_cmd)[0]==403
        assert request('mai','POST','contracts',contract_cmd)[0]==201
        assert request('mai','POST','contracts',contract_cmd)[0]==200
        assert request('mai','POST','contracts',dict(contract_cmd,terms='changed'))[0]==409
        assert request('an','GET','contracts')[1][0]['terms']=='Example internal terms'
        assert request('mai','GET','contracts/capabilities')[1]['can_decide'] is False
        assert request('an','GET','contracts/capabilities')[1]['can_decide'] is True
        assert request('mai','POST',f'contracts/{contract}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})[0]==403
        own_contract=secrets.token_hex(16)
        assert request('an','POST','contracts',{'id':own_contract,'customer':customer,'title':'Own proposal','terms':'Synthetic','op':secrets.token_hex(16)})[0]==201
        assert request('an','POST',f'contracts/{own_contract}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})[0]==403
        assert request('an','POST',f'contracts/{own_contract}/decision',{'action':'withdraw','expected_version':1,'op':secrets.token_hex(16)})[0]==200
        choices=[{'action':'approve','expected_version':1,'op':secrets.token_hex(16)} for _ in range(2)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            statuses=list(pool.map(lambda x: request('an','POST',f'contracts/{contract}/decision',x)[0], choices))
        assert sorted(statuses)==[200,409]
        assert request('an','POST',f'contracts/{contract}/decision',choices[statuses.index(200)])[0]==200
        with sqlite3.connect(db) as conn:
            conn.execute("DELETE FROM actor_roles WHERE actor='an' AND role='org-admin'")
        assert request('an','POST',f'contracts/{contract}/decision',choices[statuses.index(200)])[0]==403
        with sqlite3.connect(db) as conn:
            conn.execute("INSERT INTO actor_roles(actor,role) VALUES ('an','org-admin')")
        assert [e['action'] for e in request('mai','GET',f'contracts/{contract}/history')[1]]==['proposed','approve']
        assert next(x for x in request('an','GET','contracts')[1] if x['id']==contract)['state']=='approved_internal'
        assert request('van','POST',f'opportunities/{opportunity}/transition',{'to':'qualified','expected_version':1,'op':secrets.token_hex(16)})[0]==403
        case=secrets.token_hex(16)
        case_cmd={'id':case,'customer':customer,'title':'Synthetic support case','op':secrets.token_hex(16)}
        assert request('mai','GET','support/capabilities')[1]['can_manage'] is False
        assert request('van','GET','support/capabilities')[1]['can_manage'] is True
        assert request('mai','POST','cases',case_cmd)[0]==403
        assert request('van','POST','cases',case_cmd)[0]==201
        assert request('van','POST','cases',case_cmd)[0]==200
        assert request('mai','GET','cases')[1][0]['customer_name']=='Test customer'
        assert request('mai','POST',f'cases/{case}/transition',{'to':'in_progress','expected_version':1,'op':secrets.token_hex(16)})[0]==403
        case_start={'to':'in_progress','expected_version':1,'op':secrets.token_hex(16)}
        assert request('van','POST',f'cases/{case}/transition',case_start)[0]==200
        assert request('van','POST',f'cases/{case}/transition',case_start)[0]==200
        assert request('an','POST',f'cases/{case}/transition',{'to':'resolved','expected_version':1,'op':secrets.token_hex(16)})[0]==409
        assert request('an','POST',f'cases/{case}/transition',{'to':'resolved','expected_version':2,'op':secrets.token_hex(16)})[0]==200
        assert [e['action'] for e in request('mai','GET',f'cases/{case}/history')[1]]==['created','status:open:in_progress','status:in_progress:resolved']
        with sqlite3.connect(db) as conn:
            conn.execute("DELETE FROM actor_roles WHERE actor='van' AND role='cs'")
        assert request('van','GET','cases')[0]==403
        assert request('van','POST',f'cases/{case}/transition',case_start)[0]==403
        assert request('mai','POST',f'opportunities/{opportunity}/transition',{'to':'won','expected_version':1,'op':secrets.token_hex(16)})[0]==409
        advance={'to':'qualified','expected_version':1,'op':secrets.token_hex(16)}
        assert request('mai','POST',f'opportunities/{opportunity}/transition',advance)[0]==200
        assert request('mai','POST',f'opportunities/{opportunity}/transition',advance)[0]==200
        assert request('an','POST',f'opportunities/{opportunity}/transition',{'to':'proposal','expected_version':1,'op':secrets.token_hex(16)})[0]==409
        assert [e['action'] for e in request('an','GET',f'opportunities/{opportunity}/history')[1]]==['created','stage:lead:qualified']
        van_private=secrets.token_hex(16)
        assert request('van','POST','projects',{'id':van_private,'name':'Van private','private':True,'op':secrets.token_hex(16)})[0]==201
        assert request('an','GET',f'projects/{van_private}/tasks')[0]==404
        private_project=secrets.token_hex(16)
        private_task=secrets.token_hex(16)
        private_job=secrets.token_hex(16)
        assert request('an','POST','projects',{'id':private_project,'name':'Private project','private':True,'op':secrets.token_hex(16)})[0]==201
        assert all(p['id']!=private_project for p in request('van','GET','projects')[1])
        assert request('van','GET',f'projects/{private_project}/tasks')[0]==404
        grant={'actor':'van','action':'grant','op':secrets.token_hex(16)}
        assert request('an','POST',f'projects/{private_project}/members',grant)[0]==200
        assert request('an','POST',f'projects/{private_project}/members',grant)[0]==200
        assert request('van','POST',f'projects/{private_project}/members',{'actor':'mai','action':'grant','op':secrets.token_hex(16)})[0]==403
        private_cmd={'id':private_task,'title':'Private task','assignee':None,'op':secrets.token_hex(16)}
        assert request('van','POST',f'projects/{private_project}/tasks',private_cmd)[0]==201
        assert request('mai','GET',f'projects/{private_project}/tasks')[0]==404
        assert request('mai','GET',f'tasks/{private_task}/comments')[0]==404
        assert request('mai','POST','jobs',{'id':secrets.token_hex(16),'agent':'dev-agent','task':private_task,'instruction':'hidden','budget':1,'op':secrets.token_hex(16)})[0]==404
        assert request('van','POST','jobs',{'id':private_job,'agent':'dev-agent','task':private_task,'instruction':'private proposal','budget':1,'op':secrets.token_hex(16)})[0]==201
        assert all(j['id']!=private_job for j in request('mai','GET','jobs')[1])
        assert request('mai','GET',f'jobs/{private_job}/history')[0]==404
        reader_change={'actor':'van','action':'set_reader','op':secrets.token_hex(16)}
        assert request('an','POST',f'projects/{private_project}/members',reader_change)[0]==200
        assert request('an','POST',f'projects/{private_project}/members',reader_change)[0]==200
        assert next(p for p in request('van','GET','projects')[1] if p['id']==private_project)['can_edit'] is False
        assert len(request('van','GET',f'projects/{private_project}/tasks')[1])==1
        assert request('van','POST',f'projects/{private_project}/tasks',private_cmd)[0]==403
        assert request('van','POST',f'tasks/{private_task}/transition',{'to':'in_progress','expected_version':1,'op':secrets.token_hex(16)})[0]==403
        assert request('van','POST',f'tasks/{private_task}/comments',{'id':secrets.token_hex(16),'body':'no','op':secrets.token_hex(16)})[0]==403
        assert request('van','POST','jobs',{'id':secrets.token_hex(16),'agent':'dev-agent','task':private_task,'instruction':'no','budget':1,'op':secrets.token_hex(16)})[0]==403
        assert any(j['id']==private_job for j in request('van','GET','jobs')[1])
        assert request('van','POST',f'jobs/{private_job}/decision',{'action':'cancel','expected_version':1,'op':secrets.token_hex(16)})[0]==403
        assert request('an','POST',f'jobs/{private_job}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})[0]==200
        assert request('host2','POST','host/claim',{'job':private_job})[0]==404
        assert request('an','POST',f'projects/{private_project}/members',{'actor':'van','action':'set_writer','op':secrets.token_hex(16)})[0]==200
        assert next(p for p in request('van','GET','projects')[1] if p['id']==private_project)['can_edit'] is True
        private_claim=request('host2','POST','host/claim',{'job':private_job})[1]
        assert request('host2','GET',f'host/jobs/{private_job}/control')[1]['active'] is True
        assert request('an','POST',f'projects/{private_project}/members',{'actor':'van','action':'set_reader','op':secrets.token_hex(16)})[0]==200
        assert request('host2','GET',f'host/jobs/{private_job}/control')[1]['active'] is False
        assert request('host2','POST',f'host/jobs/{private_job}/report',{'fence':private_claim['fence'],'outcome':'success','summary':'must fail','op':secrets.token_hex(16)})[0]==404
        assert request('an','POST',f'projects/{private_project}/members',{'actor':'van','action':'set_writer','op':secrets.token_hex(16)})[0]==200
        assert request('van','POST',f'jobs/{private_job}/decision',{'action':'cancel','expected_version':3,'op':secrets.token_hex(16)})[0]==200
        assert request('an','POST',f'projects/{private_project}/members',{'actor':'van','action':'revoke','op':secrets.token_hex(16)})[0]==200
        assert request('an','POST',f'projects/{private_project}/members',{'actor':'mai','action':'grant_reader','op':secrets.token_hex(16)})[0]==200
        assert next(p for p in request('mai','GET','projects')[1] if p['id']==private_project)['can_edit'] is False
        assert request('mai','GET',f'projects/{private_project}/tasks')[0]==200
        assert request('an','POST',f'projects/{private_project}/members',{'actor':'mai','action':'revoke','op':secrets.token_hex(16)})[0]==200
        assert request('van','POST',f'projects/{private_project}/tasks',private_cmd)[0]==404
        assert request('van','GET',f'tasks/{private_task}/history')[0]==404
        assert request('van','GET',f'projects/{private_project}/history')[0]==404
        assert [e['action'] for e in request('an','GET',f'projects/{private_project}/history')[1]]==['created','grant:van','set_reader:van','set_writer:van','set_reader:van','set_writer:van','revoke:van','grant_reader:mai','revoke:mai']
        assert request('van','POST',f'tasks/{private_task}/transition',{'to':'in_progress','expected_version':1,'op':secrets.token_hex(16)})[0]==404
        assert all(j['id']!=private_job for j in request('van','GET','jobs')[1])
        assert request('van','POST',f'jobs/{private_job}/decision',{'action':'cancel','expected_version':1,'op':secrets.token_hex(16)})[0]==404
        document=secrets.token_hex(16)
        doc={'id':document,'scope':'room:finance','title':'Budget notes','body':'private sentinel','op':secrets.token_hex(16)}
        assert request('an','POST','documents',doc)[0]==403
        assert request('van','POST','documents',doc)[0]==201
        assert request('van','POST','documents',doc)[0]==200
        assert request('an','GET',f'documents/{document}')[0]==404
        assert request('an','GET',f'documents/{document}/history')[0]==404
        assert request('an','GET','documents?q=sentinel')[1]==[]
        assert len(request('van','GET','documents?q=sentinel')[1])==1
        update={'title':'Budget notes','body':'new private sentinel','expected_version':1,'op':secrets.token_hex(16)}
        assert request('van','POST',f'documents/{document}',update)[0]==200
        assert [e['action'] for e in request('van','GET',f'documents/{document}/history')[1]]==['created','updated']
        assert request('van','POST',f'documents/{document}',update)[0]==200
        assert request('van','POST',f'documents/{document}',{'title':'Old','body':'stale','expected_version':1,'op':secrets.token_hex(16)})[0]==409
        meeting=secrets.token_hex(16)
        meeting_cmd={'id':meeting,'scope':'room:finance','title':'Private meeting','starts':1800000000,'ends':1800003600,'op':secrets.token_hex(16)}
        assert request('an','POST','meetings',meeting_cmd)[0]==403
        assert request('van','POST','meetings',dict(meeting_cmd,ends=1800000000))[0]==400
        assert request('van','POST','meetings',meeting_cmd)[0]==201
        assert request('van','POST','meetings',meeting_cmd)[0]==200
        assert request('an','GET','meetings')[1]==[]
        assert request('an','GET',f'meetings/{meeting}/history')[0]==404
        assert request('van','GET','meetings')[1][0]['title']=='Private meeting'
        reschedule={'title':'Private meeting updated','starts':1800003600,'ends':1800007200,'expected_version':1,'op':secrets.token_hex(16)}
        assert request('an','POST',f'meetings/{meeting}',reschedule)[0]==404
        assert request('van','POST',f'meetings/{meeting}',reschedule)[0]==200
        assert request('van','POST',f'meetings/{meeting}',reschedule)[0]==200
        assert request('van','POST',f'meetings/{meeting}',dict(reschedule,op=secrets.token_hex(16)))[0]==409
        cancellation={'expected_version':2,'op':secrets.token_hex(16)}
        assert request('van','POST',f'meetings/{meeting}/cancel',dict(cancellation,expected_version=1))[0]==409
        assert request('van','POST',f'meetings/{meeting}/cancel',cancellation)[0]==200
        assert request('van','POST',f'meetings/{meeting}/cancel',cancellation)[0]==200
        assert [e['action'] for e in request('van','GET',f'meetings/{meeting}/history')[1]]==['scheduled','rescheduled','cancelled']
        assert request('van','POST',f'meetings/{meeting}',dict(reschedule,expected_version=3,op=secrets.token_hex(16)))[0]==409
        note=secrets.token_hex(16)
        note_cmd={'id':note,'scope':'room:finance','text':'Synthetic note','x':200,'y':300,'op':secrets.token_hex(16)}
        assert request('an','POST','whiteboard/notes',note_cmd)[0]==403
        assert request('van','POST','whiteboard/notes',dict(note_cmd,x=1001))[0]==400
        assert request('van','POST','whiteboard/notes',note_cmd)[0]==201
        assert request('van','POST','whiteboard/notes',note_cmd)[0]==200
        assert request('an','GET','whiteboard/notes?scope=room%3Afinance')[0]==403
        assert request('an','GET',f'whiteboard/notes/{note}/history')[0]==404
        note_update={'text':'Moved note','x':500,'y':600,'delete':False,'expected_version':1,'op':secrets.token_hex(16)}
        assert request('van','POST',f'whiteboard/notes/{note}',note_update)[0]==200
        assert request('van','POST',f'whiteboard/notes/{note}',note_update)[0]==200
        assert request('van','POST',f'whiteboard/notes/{note}',dict(note_update,op=secrets.token_hex(16)))[0]==409
        note_delete={'delete':True,'expected_version':2,'op':secrets.token_hex(16)}
        assert request('van','POST',f'whiteboard/notes/{note}',note_delete)[0]==200
        assert request('van','POST',f'whiteboard/notes/{note}',note_delete)[0]==200
        assert request('van','GET','whiteboard/notes?scope=room%3Afinance')[1]==[]
        assert [e['action'] for e in request('van','GET',f'whiteboard/notes/{note}/history')[1]]==['created','updated','deleted']
        assert 'finance' in request('van','GET','rooms')[1]
        assert 'finance' not in request('an','GET','rooms')[1]
        path='chat/legacy/'+urllib.parse.quote('room:finance',safe='')
        message={'id':secrets.token_hex(16),'body':'private test message'}
        assert request('an','GET',path)[0]==403
        assert request('van','POST','messages/room%3Afinance',message)[0]==404
        with sqlite3.connect(db) as connection:
            connection.execute("INSERT INTO messages VALUES (?, 'room:finance', 'van', ?, 100)",(message['id'],message['body']))
        # The local operator can change restricted-room membership; it is not
        # a remotely authenticated administration interface.
        assert subprocess.run([str(binary),'room','grant','finance','an'],env=env).returncode==0
        assert 'finance' in request('an','GET','rooms')[1]
        assert request('an','GET',path)[0]==200
        assert subprocess.run([str(binary),'room','grant','finance','an'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0
        assert subprocess.run([str(binary),'room','grant','lobby','an'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0
        assert subprocess.run([str(binary),'room','grant','finance','mona'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0
        assert subprocess.run([str(binary),'room','revoke','finance','an'],env=env).returncode==0
        assert 'finance' not in request('an','GET','rooms')[1]
        assert request('an','GET',path)[0]==403
        with sqlite3.connect(db) as connection:
            assert connection.execute("SELECT action FROM security_audit WHERE subject='an' AND action IN ('room_grant:finance','room_revoke:finance') ORDER BY seq").fetchall()==[('room_grant:finance',),('room_revoke:finance',)]
        lobby='chat/legacy/'+urllib.parse.quote('room:lobby',safe='')
        with sqlite3.connect(db) as connection:
            connection.execute("INSERT INTO messages VALUES (?, 'room:lobby', 'an', 'hello', 100)",(secrets.token_hex(16),))
        assert len(request('van','GET',lobby)[1])==1
        # Presence lives in the realtime capability and is authorized by tickets.
        rt = {who: Realtime(port, tokens[who]) for who in ('an', 'van')}
        sessions = {who: secrets.token_hex(16) for who in ('an', 'van')}
        for who in sessions:
            assert rt[who].publish(sessions[who],'lobby',12,12,1)==204
        assert len(rt['an'].presence())==2
        assert rt['van'].publish(sessions['van'],'lobby',13,12,2)==204
        visible = rt['an'].presence()
        assert any(p['actor']=='van' and p['x']==13 and p['y']==12 for p in visible)
        assert rt['an'].publish(sessions['an'],'lobby',25,23,2)==403
        assert rt['an'].publish(sessions['an'],'lobby',0,0,2)==403
        assert rt['an'].publish(sessions['an'],'finance',25,23,2)==403
        assert rt['an'].publish(sessions['an'],'lobby',9,9,2)==204
        assert rt['an'].leave(sessions['van'])==204
        assert len(rt['an'].presence())==2
        assert rt['van'].leave(sessions['van'])==204
        assert len(rt['an'].presence())==1
        assert rt['an'].request('GET','presence',ticket_override='00.00')[0]==401
        status, _ = rt['an'].request('GET','presence',ticket_override=tokens['an'])
        assert status==401
        stop(); start()
        assert request('an','GET','me')[1]['authority_id']==authority_id
        assert len(request('van','GET',path)[1])==1
        assert request('an','GET',f'projects/{project}/tasks')[1][0]['state']=='in_progress'
        with sqlite3.connect(db) as conn:
            conn.execute("DELETE FROM room_members WHERE room='finance' AND actor='van'")
            conn.execute("DELETE FROM actor_roles WHERE actor='mai' AND role='sales'")
            conn.execute("DELETE FROM actor_roles WHERE actor='van' AND role='accountant'")
        assert request('van','GET',path)[0]==403
        assert request('mai','GET','customers')[0]==403
        assert request('mai','GET','contracts')[0]==403
        assert request('mai','GET','bookings')[0]==403
        assert request('mai','POST','bookings',replacement_booking)[0]==403
        assert request('mai','POST','contracts',contract_cmd)[0]==403
        assert request('mai','POST',f'opportunities/{opportunity}/transition',advance)[0]==403
        assert request('van','GET','expenses')[0]==403
        assert 'finance' not in request('van','GET','rooms')[1]
        assert request('van','GET',f'documents/{document}')[0]==404
        assert request('van','GET',f'documents/{document}/history')[0]==404
        assert request('van','POST',f'meetings/{meeting}/cancel',cancellation)[0]==404
        assert request('van','POST',f'meetings/{meeting}',reschedule)[0]==404
        assert request('van','GET',f'meetings/{meeting}/history')[0]==404
        assert request('van','GET',f'whiteboard/notes/{note}/history')[0]==404
        assert request('van','POST',f'whiteboard/notes/{note}',note_delete)[0]==404
        assert request('van','GET','meetings')[1]==[]
        assert request('van','GET','documents?q=sentinel')[1]==[]
        stop(); start()
        assert request('van','GET',path)[0]==403
        assert request('mai','GET','customers')[0]==403
        assert request('van','GET','expenses')[0]==403
        assert request('van','GET',f'projects/{private_project}/tasks')[0]==404
        assert all(j['id']!=private_job for j in request('van','GET','jobs')[1])
        snapshot=Path(directory)/'backup.sqlite3'
        subprocess.run([str(binary),'backup',str(snapshot)],env=env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        assert snapshot.stat().st_mode & 0o777 == 0o600
        digest=hashlib.sha256(snapshot.read_bytes()).digest()
        repeat=subprocess.run([str(binary),'backup',str(snapshot)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        assert repeat.returncode!=0 and hashlib.sha256(snapshot.read_bytes()).digest()==digest
        sidecar_dest=Path(directory)/'sidecar.sqlite3'
        sidecar=Path(str(sidecar_dest)+'-wal'); sidecar.write_text('preserve')
        blocked=subprocess.run([str(binary),'backup',str(sidecar_dest)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        assert blocked.returncode!=0 and sidecar.read_text()=='preserve' and not sidecar_dest.exists()
        stop()
        restored_path=Path(directory)/'restored.sqlite3'
        restore_env={**env,'MONASTACK_DB':str(restored_path)}
        invalid=Path(directory)/'invalid.sqlite3'; invalid.write_text('not a database')
        failed_restore=subprocess.run([str(binary),'restore',str(invalid)],env=restore_env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        assert failed_restore.returncode!=0 and not restored_path.exists() and invalid.read_text()=='not a database'
        subprocess.run([str(binary),'restore',str(snapshot)],env=restore_env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        restore_again=subprocess.run([str(binary),'restore',str(snapshot)],env=restore_env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        assert restore_again.returncode!=0
        env['MONASTACK_DB']=str(restored_path)
        start()
        assert request('an','GET','me')[1]['authority_id']==authority_id
        assert request('an','GET',f'projects/{project}/tasks')[1][0]['state']=='in_progress'
        assert request('van','GET',path)[0]==403
        assert request('van','GET',f'projects/{private_project}/tasks')[0]==404
        assert request('mai','GET','customers')[0]==403
        session=secrets.token_hex(16)
        van_rt, an_rt = Realtime(port, tokens['van']), Realtime(port, tokens['an'])
        van_ticket, realtime_url = ticket(port, tokens['van'])
        assert van_rt.publish(session,'lobby',14,13,1)==204
        subprocess.run([str(binary),'revoke'],env=env,input=tokens['van'],text=True,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        assert request('van','GET','me')[0]==401
        # The credential change advances the epoch: the unexpired ticket and
        # its presence stop working without waiting for expiry.
        assert all(p['actor']!='van' for p in an_rt.presence())
        assert an_rt.request('GET','presence',ticket_override=van_ticket)[0]==401
        assert request('an','GET','me')[0]==200
        duplicate_revoke=subprocess.run([str(binary),'revoke'],env=env,input=tokens['van'],text=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        assert duplicate_revoke.returncode!=0
        stop()
        with sqlite3.connect(restored_path) as restored:
            assert restored.execute('select count(*) from messages').fetchone()[0]==2
            assert restored.execute('select count(*) from task_audit').fetchone()[0]==16
            assert restored.execute('select count(*) from agent_job_audit').fetchone()[0]==27
            assert restored.execute('select count(*) from document_audit').fetchone()[0]==2
            assert restored.execute('select count(*) from customer_audit').fetchone()[0]==2
            assert restored.execute('select count(*) from contract_audit').fetchone()[0]==4
            assert restored.execute('select count(*) from booking_audit').fetchone()[0]==5
            assert restored.execute("select state from contract_proposals where id=?",(contract,)).fetchone()[0]=='approved_internal'
            assert restored.execute('select count(*) from opportunity_audit').fetchone()[0]==2
            assert restored.execute('select count(*) from support_case_audit').fetchone()[0]==3
            assert restored.execute('select count(*) from meeting_audit').fetchone()[0]==3
            assert restored.execute('select count(*) from whiteboard_audit').fetchone()[0]==3
            assert restored.execute('select count(*) from payment_audit').fetchone()[0]==4
            assert restored.execute('select count(*) from expense_audit').fetchone()[0]==4
            assert restored.execute('select count(*) from journal_audit').fetchone()[0]==5
            assert restored.execute("select count(*) from journal_entries where state='posted' and debit != credit and minor > 0").fetchone()[0]==2
            assert restored.execute('select count(*) from leave_audit').fetchone()[0]==11
            assert restored.execute("select state from leave_requests where id=?",(leave_id,)).fetchone()[0]=='cancelled'
            assert restored.execute('select count(*) from incident_comments').fetchone()[0]==2
            assert restored.execute("select count(*) from security_audit where action='credential_revoked'").fetchone()[0]==1
            assert restored.execute("select count(*) from security_audit where action like 'role_%'").fetchone()[0]==8
        print('HTTP smoke: multiple identities, authorization, workflows, persistence, deduplication, revocation, live backup and restore passed')
    finally:
        if process and process.poll() is None:
            stop()
