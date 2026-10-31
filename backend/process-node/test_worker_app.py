"""Synthetic worker report displayed by one real macOS app instance."""
import json
import os
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

# The app signs in with the enrolled device token, not a password (ADR 0008).
os.environ.setdefault('MONASTACK_SIGN_IN', 'token')

root=Path(__file__).resolve().parents[2]
node=root/'backend/office-node/target/debug/monastack-office-node'
image=subprocess.check_output(['docker','image','inspect','alpine:3.23','--format','{{.Id}}'],text=True).strip()
with tempfile.TemporaryDirectory(prefix='monastack-worker-app-') as directory:
    tmp=Path(directory)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    env={**os.environ,'MONASTACK_DB':str(tmp/'office.sqlite3'),'MONASTACK_NODE_PORT':str(port),'MONASTACK_TEST_ISOLATED_OUTBOX':'1'}
    tokens={who:secrets.token_hex(32) for who in ('an','van')}
    env['MONASTACK_TEST_AN']=tokens['an']
    for who,token in tokens.items():subprocess.run([str(node),'enroll',who],env=env,input=token,text=True,check=True)
    host_token=secrets.token_hex(32);token_file=tmp/'host-token';token_file.write_text(host_token);token_file.chmod(0o600)
    subprocess.run([str(node),'host-enroll','synthetic-app-host-000001','van','dev-agent'],env=env,input=host_token,text=True,check=True)
    subprocess.run([str(node),'host-claims','enable'],env=env,check=True)
    command=tmp/'command.json';command.write_text(json.dumps(['/bin/cat']))
    server=subprocess.Popen([str(node)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    base=f'http://127.0.0.1:{port}'
    def request(who,method,path,body=None):
        data=None if body is None else json.dumps(body).encode()
        req=urllib.request.Request(base+'/v1/'+path,method=method,data=data,headers={'Authorization':'Bearer '+tokens[who],'Content-Type':'application/json'})
        with urllib.request.urlopen(req,timeout=3) as response:
            return response.status
    try:
        for _ in range(100):
            if server.poll() is not None:raise RuntimeError('node failed to start')
            try:request('an','GET','me');break
            except (OSError,urllib.error.URLError):time.sleep(.05)
        else:raise RuntimeError('node did not start')
        job=secrets.token_hex(16)
        assert request('van','POST','jobs',{'id':job,'agent':'dev-agent','task':None,'instruction':'Synthetic app host report','budget':5,'op':secrets.token_hex(16)})==201
        assert request('an','POST',f'jobs/{job}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})==200
        subprocess.run([sys.executable,str(root/'backend/process-node/worker.py'),'--node',base,'--token-file',str(token_file),'--image',image,'--command-file',str(command),'--scratch-root',str(tmp)],check=True,timeout=35)
        subprocess.run(['flutter','test','integration_test/host_report_test.dart','-d','macos'],cwd=root/'app',env=env,check=True,timeout=240)
    finally:
        server.terminate();server.wait(timeout=5)
