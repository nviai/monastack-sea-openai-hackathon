"""End-to-end synthetic worker test with an isolated local node and database."""
import json
import os
import secrets
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from worker import read_token, validate_node

for invalid in ('http://example.com:1234','https://127.0.0.1:1234','http://127.0.0.1:1234/path','http://127.0.0.1:1234?x=1'):
    try:
        validate_node(invalid)
        raise AssertionError('non-loopback node accepted')
    except ValueError:
        pass

root=Path(__file__).resolve().parents[2]
node=root/'backend/office-node/target/debug/monastack-office-node'
worker=root/'backend/process-node/worker.py'
image=subprocess.check_output(['docker','image','inspect','alpine:3.23','--format','{{.Id}}'],text=True).strip()
with tempfile.TemporaryDirectory(prefix='monastack-worker-test-') as directory:
    tmp=Path(directory);db=tmp/'office.sqlite3'
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    env={**os.environ,'MONASTACK_DB':str(db),'MONASTACK_NODE_PORT':str(port)}
    human={who:secrets.token_hex(32) for who in ('an','van')}
    for who,token in human.items(): subprocess.run([str(node),'enroll',who],env=env,input=token,text=True,check=True)
    host_token=secrets.token_hex(32);host_id='synthetic-worker-0000001'
    subprocess.run([str(node),'host-enroll',host_id,'van','dev-agent'],env=env,input=host_token,text=True,check=True)
    subprocess.run([str(node),'host-claims','enable'],env=env,check=True)
    token_file=tmp/'host-token';token_file.write_text(host_token);token_file.chmod(0o600)
    token_file.chmod(0o644)
    try:
        read_token(token_file)
        raise AssertionError('non-private token accepted')
    except ValueError:
        pass
    token_file.chmod(0o600)
    link=tmp/'host-token-link';link.symlink_to(token_file)
    try:
        read_token(link)
        raise AssertionError('token symlink accepted')
    except OSError:
        pass
    command=tmp/'command.json'
    server=subprocess.Popen([str(node)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    base=f'http://127.0.0.1:{port}'
    def request(who,method,path,body=None):
        data=None if body is None else json.dumps(body).encode()
        req=urllib.request.Request(base+'/v1/'+path,method=method,data=data,headers={'Authorization':'Bearer '+human[who],'Content-Type':'application/json'})
        with urllib.request.urlopen(req,timeout=3) as response:
            raw=response.read()
            return response.status,json.loads(raw) if raw else None
    def start_job(text, task=None):
        job=secrets.token_hex(16)
        assert request('van','POST','jobs',{'id':job,'agent':'dev-agent','task':task,'instruction':text,'budget':5,'op':secrets.token_hex(16)})[0]==201
        assert request('an','POST',f'jobs/{job}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})[0]==200
        return job
    def worker_args(): return [sys.executable,str(worker),'--node',base,'--token-file',str(token_file),'--image',image,'--command-file',str(command),'--scratch-root',str(tmp)]
    def running_for(job):
        return subprocess.check_output(['docker','ps','--quiet','--filter','label=com.monastack.job='+job],text=True).strip()
    def wait_for_container(job,process):
        for _ in range(100):
            if running_for(job): return
            if process.poll() is not None: raise RuntimeError('worker exited before container started')
            time.sleep(.05)
        raise RuntimeError('container did not start')
    process=None
    try:
        for _ in range(100):
            if server.poll() is not None: raise RuntimeError('node failed to start')
            try: request('an','GET','me');break
            except (OSError,urllib.error.URLError): time.sleep(.05)
        else: raise RuntimeError('node did not start')
        codex_image=os.environ.get('MONASTACK_SYNTHETIC_CODEX_IMAGE')
        if codex_image:
            command.write_text(json.dumps(['/usr/local/bin/node','/opt/codex-spike/probe.js']))
            codex_job=start_job('Synthetic Codex instruction')
            args=worker_args()
            args[args.index('--image')+1]=codex_image
            result=subprocess.run(args+['--codex-state-tmpfs'],capture_output=True,text=True,timeout=35)
            assert result.returncode==0 and result.stdout.strip()=='host report recorded', (result.returncode,result.stdout,result.stderr)
            record=next(j for j in request('van','GET','jobs')[1] if j['id']==codex_job)
            assert record['state']=='host_reported' and 'SYNTHETIC_CODEX_RESPONSE' in record['report_summary'], record
        command.write_text(json.dumps(['/bin/cat']))
        job=start_job('Synthetic worker output')
        result=subprocess.run(worker_args(),capture_output=True,text=True,timeout=35)
        assert result.returncode==0 and result.stdout.strip()=='host report recorded', (result.returncode,result.stdout,result.stderr)
        record=next(j for j in request('van','GET','jobs')[1] if j['id']==job)
        assert record['state']=='host_reported' and record['report_summary']=='Synthetic worker output'
        command.write_text(json.dumps(['/bin/sh','-c','sleep 15']))
        job=start_job('Synthetic cancellation')
        process=subprocess.Popen(worker_args(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        for _ in range(100):
            record=next(j for j in request('van','GET','jobs')[1] if j['id']==job)
            if record['state']=='host_claimed':break
            if process.poll() is not None: raise RuntimeError('worker exited before claim')
            time.sleep(.05)
        else: raise RuntimeError('worker did not claim')
        wait_for_container(job,process)
        assert request('van','POST',f'jobs/{job}/decision',{'action':'cancel','expected_version':3,'op':secrets.token_hex(16)})[0]==200
        stdout,stderr=process.communicate(timeout=15)
        assert process.returncode==0 and stdout.strip()=='claim stopped; no report submitted', (process.returncode,stdout,stderr)
        assert not running_for(job)
        with sqlite3.connect(db) as conn:
            assert conn.execute('SELECT COUNT(*) FROM host_reports WHERE job=?',(job,)).fetchone()[0]==0
        disabled_job=start_job('Synthetic global stop')
        process=subprocess.Popen(worker_args(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        wait_for_container(disabled_job,process)
        subprocess.run([str(node),'host-claims','disable'],env=env,check=True)
        stdout,stderr=process.communicate(timeout=15)
        assert process.returncode==0 and stdout.strip()=='claim stopped; no report submitted', (process.returncode,stdout,stderr)
        assert not running_for(disabled_job)
        subprocess.run([str(node),'host-claims','enable'],env=env,check=True)
        with sqlite3.connect(db) as conn:
            assert conn.execute('SELECT deadline FROM host_claims WHERE job=?',(disabled_job,)).fetchone()[0]==0
        crash_job=start_job('Synthetic host crash')
        process=subprocess.Popen(worker_args(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        wait_for_container(crash_job,process)
        process.kill();process.wait(timeout=5)
        for _ in range(100):
            if not running_for(crash_job): break
            time.sleep(.05)
        assert not running_for(crash_job), 'watchdog did not stop the test container'
        assert next(j for j in request('van','GET','jobs')[1] if j['id']==crash_job)['state']=='host_claimed'
        project=secrets.token_hex(16);task=secrets.token_hex(16)
        assert request('an','POST','projects',{'id':project,'name':'Synthetic private project','private':True,'op':secrets.token_hex(16)})[0]==201
        assert request('an','POST',f'projects/{project}/members',{'actor':'van','action':'grant','op':secrets.token_hex(16)})[0]==200
        assert request('an','POST',f'projects/{project}/tasks',{'id':task,'title':'Synthetic private task','assignee':None,'op':secrets.token_hex(16)})[0]==201
        private_job=start_job('Synthetic scope change',task)
        process=subprocess.Popen(worker_args(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        wait_for_container(private_job,process)
        assert request('an','POST',f'projects/{project}/members',{'actor':'van','action':'set_reader','op':secrets.token_hex(16)})[0]==200
        stdout,stderr=process.communicate(timeout=15)
        assert process.returncode==0 and stdout.strip()=='claim stopped; no report submitted', (process.returncode,stdout,stderr)
        assert not running_for(private_job)
        disconnect_job=start_job('Synthetic node outage')
        process=subprocess.Popen(worker_args(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        wait_for_container(disconnect_job,process)
        server.terminate();server.wait(timeout=5)
        stdout,stderr=process.communicate(timeout=15)
        assert process.returncode==0 and stdout.strip()=='claim stopped; no report submitted', (process.returncode,stdout,stderr)
        assert not running_for(disconnect_job)
        print('Worker integration: synthetic report, cancellation, global stop, crash watchdog, permission loss and node outage passed')
    finally:
        if process is not None and process.poll() is None:
            process.terminate();process.wait(timeout=5)
        if server.poll() is None:
            server.terminate();server.wait(timeout=5)
