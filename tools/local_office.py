"""Start, stop or inspect the same-machine server + member + macOS app."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import sqlite3
import subprocess
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT/'runtime'
NODE = ROOT/'backend/office-node/target/debug/monastack-office-node'
APP = ROOT/'app/build/macos/Build/Products/Debug/monastack.app/Contents/MacOS/monastack'
SPECS = {
    'server': (47830, 47831, RUNTIME/'db/server-office.sqlite3', '1'),
    'client': (47840, 47841, RUNTIME/'db/client-office.sqlite3', '0'),
}

SERVER_CONFIG = RUNTIME/'server-address.json'
SERVER_HOST = os.environ.get('MONASTACK_SERVER_HOST') or (json.loads(SERVER_CONFIG.read_text())['host'] if SERVER_CONFIG.exists() else '127.0.0.1')
MEDIA = {'server': (7880,7881,7882)}

def media_environment(name):
    signal_port,tcp_port,udp_port = MEDIA[name]
    return {**os.environ, 'MONASTACK_RUNTIME_DIR':str(RUNTIME),
        'MONASTACK_DEV_DIR':str(RUNTIME/'media'/name),
        'MONASTACK_MEDIA_NAME':f'monastack-livekit-{name}',
        'MONASTACK_MEDIA_BIND_HOST':'0.0.0.0',
        'MONASTACK_MEDIA_NODE_IP':SERVER_HOST,
        'MONASTACK_MEDIA_SIGNAL_PORT':str(signal_port),
        'MONASTACK_MEDIA_TCP_PORT':str(tcp_port),
        'MONASTACK_MEDIA_UDP_PORT':str(udp_port)}

def start_media():
    for name in MEDIA:
        result = subprocess.run(['docker','inspect','--format','{{.State.Running}}',f'monastack-livekit-{name}'], capture_output=True,text=True)
        if result.returncode == 0 and result.stdout.strip() == 'true':
            continue
        subprocess.run(['sh',str(ROOT/'backend/media/livekit-dev.sh'),'start'],
            env=media_environment(name),cwd=ROOT,check=True,capture_output=True)
        # Wait for the signaling/API listener before starting the control plane.
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1',MEDIA[name][0]),timeout=.3):
                    break
            except OSError:
                time.sleep(.1)
        else:
            raise RuntimeError(f'LiveKit {name} did not start')

def call(port, path, body=None, token=None, method=None):
    request = urllib.request.Request(f'http://127.0.0.1:{port}/v1/{path}',
        data=None if body is None else json.dumps(body).encode(), method=method,
        headers={'Content-Type': 'application/json', **({'Authorization': 'Bearer '+token} if token else {})})
    with urllib.request.urlopen(request, timeout=10) as response:
        text = response.read()
        return json.loads(text) if text else None

def environment(name):
    port, realtime, db, seed = SPECS[name]
    values = {**os.environ, 'MONASTACK_RUNTIME_DIR':str(RUNTIME),
        'MONASTACK_ENV_FILE':str(RUNTIME/'.env'), 'MONASTACK_DB':str(db),
        'MONASTACK_NODE_PORT':str(port), 'MONASTACK_REALTIME_PORT':str(realtime),
        'MONASTACK_REALTIME':'embedded' if name == 'server' else 'off', 'MONASTACK_SEED_COMPANY':seed,
        'MONASTACK_WORKSPACE_MODE':'identity' if name == 'server' else 'shared',
        'MONASTACK_BIND_HOST':'0.0.0.0'}
    if name == 'server':
        values.update({'MONASTACK_MEDIA_URL':'ws://127.0.0.1:7880',
            'MONASTACK_MEDIA_PUBLIC_URL':f'ws://{SERVER_HOST}:7880',
            'MONASTACK_REALTIME_PUBLIC_URL':f'http://{SERVER_HOST}:47831',
            'MONASTACK_MEDIA_KEY_FILE':str(RUNTIME/'media/server/media.key')})
    return values

def pid_file(name):
    return RUNTIME/'pids'/f'{name}.pid'

def running(name):
    file = pid_file(name)
    if not file.exists():
        return None
    pid = int(file.read_text().strip())
    command = subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True).stdout
    expected = str(APP if name in ('app', 'lan-client') else NODE)
    return pid if expected in command else None

def spawn(name, command, env):
    if running(name):
        return
    log = RUNTIME/'logs'/f'{name}.log'
    with log.open('ab') as output:
        process = subprocess.Popen(command, cwd=ROOT, env=env,
            stdin=subprocess.DEVNULL, stdout=output, stderr=output, start_new_session=True)
    pid_file(name).write_text(str(process.pid)+'\n')
    if name != 'app':
        port = SPECS[name][0]
        for _ in range(400):
            if process.poll() is not None:
                raise RuntimeError(f'{name} exited; inspect runtime/logs/{name}.log')
            try:
                call(port,'workspace')
                return
            except (OSError, urllib.error.HTTPError):
                time.sleep(.05)
        raise RuntimeError(f'{name} startup timeout')

def start(with_app):
    for directory in ['db','logs','pids']:
        (RUNTIME/directory).mkdir(parents=True,exist_ok=True,mode=0o700)
    if not NODE.is_file():
        raise RuntimeError('Build office-node first.')
    if not (RUNTIME/'.env').exists():
        raise RuntimeError('Prepare runtime/.env from .env.example first.')
    for name, (port, realtime, _, _) in SPECS.items():
        if running(name):
            continue
        for value in ([port,realtime] if name == 'server' else [port]):
            with socket.socket() as sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    sock.bind(('0.0.0.0', value))
                except OSError:
                    raise RuntimeError(f'Port {value} is already occupied; existing service was left untouched.')
    start_media()
    spawn('server',[str(NODE)],environment('server'))
    client_db = SPECS['client'][2]
    if not client_db.exists():
        subprocess.run([str(NODE),'setup-code'],env=environment('client'),cwd=ROOT,
            check=True,capture_output=True)
    with sqlite3.connect(client_db) as connection:
        role = connection.execute("SELECT value FROM metadata WHERE key='identity-role'").fetchone()
    if role is None:
        session = call(47830,'auth/login',{'username':'triet.le',
            'password':'NviaiSeaxOpenAIHackathon','device':'Local node setup','platform':'operator'})
        token = session['access_token']
        try:
            joined = call(47830,'admin/nodes',{'name':'Local client node'},token)
            subprocess.run([str(NODE),'join','http://127.0.0.1:47830'],
                input=joined['code'],text=True,capture_output=True,check=True,
                env=environment('client'),cwd=ROOT)
        finally:
            call(47830,'auth/logout',token=token,method='POST')
    elif role[0] != 'member':
        raise RuntimeError('Client database is already a master; preserved without modification.')
    spawn('client',[str(NODE)],environment('client'))
    if with_app:
        if not APP.is_file():
            raise RuntimeError('Build app with flutter build macos --debug first; both nodes are running.')
        spawn('app',[str(APP)],environment('client'))
    status()

def status():
    for name, (port, realtime, db, _) in SPECS.items():
        if not running(name):
            print(f'{name}: stopped')
            continue
        state = call(port,'workspace')
        print(f'{name}: PID {running(name)}, {state["role"]}, API 0.0.0.0:{port}, realtime {('0.0.0.0:'+str(realtime)) if name == 'server' else 'shared server :47831'}, DB {db.relative_to(ROOT)}')
    for name, ports in MEDIA.items():
        check = subprocess.run(['docker','inspect','--format','{{.State.Running}}',f'monastack-livekit-{name}'],capture_output=True,text=True)
        print(f'LiveKit {name}: {"running" if check.returncode == 0 and check.stdout.strip() == "true" else "stopped"}; signaling 0.0.0.0:{ports[0]}, RTC TCP {ports[1]}, UDP {ports[2]}')
    if running('lan-client'): print(f'LAN client: running, PID {running("lan-client")}')
    print(f'app: {"running, PID "+str(running("app")) if running("app") else "stopped"}; connects to 127.0.0.1:47840')

def stop():
    for name in ['lan-client','app','client','server']:
        pid = running(name)
        if pid:
            os.kill(pid,signal.SIGTERM)
            print(f'{name}: stop requested')
            for _ in range(50):
                if not running(name): break
                time.sleep(.1)
        pid_file(name).unlink(missing_ok=True)
    for name in MEDIA:
        subprocess.run(['sh',str(ROOT/'backend/media/livekit-dev.sh'),'stop'],env=media_environment(name),check=True,capture_output=True)

if __name__ == '__main__':
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['start','status','stop'])
    parser.add_argument('--no-app',action='store_true',help='start only the two nodes')
    args = parser.parse_args()
    try:
        if args.action == 'start': start(not args.no_app)
        elif args.action == 'stop': stop()
        else: status()
    except Exception as error:
        # Do not expose credentials, HTTP bodies or subprocess command input.
        raise SystemExit(f'Local office failed ({type(error).__name__}). Check runtime/logs or occupied ports.')
