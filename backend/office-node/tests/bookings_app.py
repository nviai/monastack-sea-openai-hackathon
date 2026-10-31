"""Exercise customer booking creation in a disposable macOS app/node fixture."""
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
with tempfile.TemporaryDirectory(prefix='monastack-booking-app-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
    token=secrets.token_hex(32)
    env={**os.environ,'MONASTACK_DB':str(Path(directory)/'office.sqlite3'),'MONASTACK_NODE_PORT':str(port),'MONASTACK_TEST_TOKEN':token,'MONASTACK_TEST_ISOLATED_OUTBOX':'1'}
    subprocess.run([str(node),'enroll','an'],env=env,input=token,text=True,check=True)
    server=subprocess.Popen([str(node)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        for _ in range(100):
            if server.poll() is not None: raise RuntimeError('node failed')
            try: urllib.request.urlopen(f'http://127.0.0.1:{port}/v1/me',timeout=.2)
            except urllib.error.HTTPError: break
            except OSError: time.sleep(.05)
        else: raise RuntimeError('node did not start')
        payload=json.dumps({'id':secrets.token_hex(16),'name':'Synthetic customer','email':'','notes':'','op':secrets.token_hex(16)}).encode()
        req=urllib.request.Request(f'http://127.0.0.1:{port}/v1/customers',data=payload,method='POST',headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
        with urllib.request.urlopen(req,timeout=3) as response: assert response.status==201
        subprocess.run(['flutter','test','integration_test/bookings_test.dart','-d','macos'],cwd=root/'app',env=env,check=True,timeout=90)
        with sqlite3.connect(env['MONASTACK_DB']) as conn:
            assert conn.execute("SELECT title,state,version FROM customer_bookings").fetchall()==[('Synthetic booking','cancelled',3)]
    finally:
        server.terminate();server.wait(timeout=5)
