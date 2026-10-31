"""Exercise payment authorization revocation in an isolated app/node fixture."""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

# The app signs in with the enrolled device token, not a password (ADR 0008).
os.environ.setdefault('MONASTACK_SIGN_IN', 'token')
root=Path(__file__).resolve().parents[3]
node=root/'backend/office-node/target/debug/monastack-office-node'
with tempfile.TemporaryDirectory(prefix='monastack-payment-app-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    tokens={actor:secrets.token_hex(32) for actor in ('an','van')}
    env={**os.environ,'MONASTACK_DB':str(Path(directory)/'office.sqlite3'),'MONASTACK_NODE_PORT':str(port),'MONASTACK_TEST_TOKEN':tokens['an'],'MONASTACK_TEST_ISOLATED_OUTBOX':'1'}
    for actor,token in tokens.items(): subprocess.run([str(node),'enroll',actor],env=env,input=token,text=True,check=True)
    server=subprocess.Popen([str(node)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if server.poll() is not None: raise RuntimeError('node failed')
            try: urllib.request.urlopen(f'http://127.0.0.1:{port}/v1/me',timeout=.2)
            except urllib.error.HTTPError: break
            except OSError: time.sleep(.05)
        else: raise RuntimeError('node did not start')
        def post(actor,path,body):
            req=urllib.request.Request(f'http://127.0.0.1:{port}/v1/{path}',data=json.dumps(body).encode(),method='POST',headers={'Authorization':'Bearer '+tokens[actor],'Content-Type':'application/json'})
            with urllib.request.urlopen(req,timeout=3) as response: return response.status
        import sqlite3
        expense=secrets.token_hex(16)
        assert post('van','expenses',{'id':expense,'description':'Synthetic','minor':100,'currency':'VND','op':secrets.token_hex(16)})==201
        assert post('an',f'expenses/{expense}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})==200
        payment=secrets.token_hex(16)
        assert post('van','payment-authorizations',{'id':payment,'expense':expense,'op':secrets.token_hex(16)})==201
        assert post('an',f'payment-authorizations/{payment}/decision',{'action':'approve','expected_version':1,'op':secrets.token_hex(16)})==200
        subprocess.run(['flutter','test','integration_test/payment_revocation_test.dart','-d','macos'],cwd=root/'app',env=env,check=True,timeout=240)
        with sqlite3.connect(env['MONASTACK_DB']) as conn:
            assert conn.execute('SELECT state,version FROM payment_authorizations WHERE id=?',(payment,)).fetchone()==('revoked',3)

    finally:
        server.terminate();server.wait(timeout=5)
