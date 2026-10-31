"""Start, stop or inspect the same-machine server + member + macOS app."""
import argparse
import json
import os
from pathlib import Path
import signal
import shutil
import socket
import sqlite3
import subprocess
import time
import urllib.error
import urllib.request
import sys
from matrix_stack import Stack, zellij_tab
from visible_service import launch_service

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path(os.environ.get('MONASTACK_RUNTIME_DIR', ROOT/'runtime')).resolve()
SESSION = 'monastack-matrix-server'
MATRIX = Stack(RUNTIME, session=SESSION)
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

def media_owned(name):
    if not shutil.which('docker'): return False
    result=subprocess.run(['docker','inspect',f'monastack-livekit-{name}'],capture_output=True,text=True)
    if result.returncode: return False
    expected=str((RUNTIME/'media'/name/'livekit.yaml').resolve())
    mounts=json.loads(result.stdout)[0]['Mounts']
    if not any(m['Source']==expected and m['Destination']=='/livekit.yaml' for m in mounts):
        raise RuntimeError(f'LiveKit {name} belongs to another runtime; left untouched')
    return True

def start_media():
    if not shutil.which('docker') or subprocess.run(['docker','info'],capture_output=True).returncode:
        print('LiveKit: unavailable (Docker not installed); office nodes will still start')
        return
    for name in MEDIA:
        owned=media_owned(name)
        result = subprocess.run(['docker','inspect','--format','{{.State.Running}}',f'monastack-livekit-{name}'], capture_output=True,text=True)
        if result.returncode == 0 and result.stdout.strip() == 'true':
            continue
        for port,kind in [(MEDIA[name][0],socket.SOCK_STREAM),(MEDIA[name][1],socket.SOCK_STREAM),(MEDIA[name][2],socket.SOCK_DGRAM)]:
            with socket.socket(socket.AF_INET,kind) as sock:
                sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
                try: sock.bind(('0.0.0.0',port))
                except OSError: raise RuntimeError(f'Port {port} is occupied; service left untouched')
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

def environment(name, with_matrix=True):
    port, realtime, db, seed = SPECS[name]
    values = {**os.environ, 'MONASTACK_RUNTIME_DIR':str(RUNTIME),
        'MONASTACK_ENV_FILE':str(RUNTIME/'.env'), 'MONASTACK_DB':str(db),
        'MONASTACK_NODE_PORT':str(port), 'MONASTACK_REALTIME_PORT':str(realtime),
        'MONASTACK_REALTIME':'embedded' if name == 'server' else 'off', 'MONASTACK_SEED_COMPANY':seed,
        'MONASTACK_WORKSPACE_MODE':'identity' if name == 'server' else 'shared',
        'MONASTACK_BIND_HOST':'0.0.0.0',
        **({'LIVE_AGENTS_ENABLED':'0'} if name != 'server' else {})}
    values.pop('MONASTACK_MATRIX_DIR', None)
    values.pop('MONASTACK_MATRIX_PUBLIC_URL', None)
    values['MONASTACK_MATRIX_DISABLED'] = '0' if with_matrix else '1'
    if name == 'server' and with_matrix:
        values.update({'MONASTACK_MATRIX_DIR':str(RUNTIME/'matrix'),
            'MONASTACK_MATRIX_PUBLIC_URL':os.environ.get('MONASTACK_MATRIX_PUBLIC_URL',f'http://{SERVER_HOST}:8008')})
    if name == 'server' and shutil.which('docker'):
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
    expected = str(ROOT/'backend/live-agent/worker.py' if name == 'voice-worker' else ROOT/'tools/matrix_proxy.py' if name == 'matrix-gateway' else APP if name in ('app', 'lan-client') else NODE)
    candidates = [expected]
    if name in ('app', 'lan-client'):
        candidates.extend(str(ROOT/f'app/build/macos/Build/Products/{mode}/monastack.app/Contents/MacOS/monastack') for mode in ('Debug', 'Release'))
    return pid if any(path in command for path in candidates) else None

def spawn(name, command, env):
    if running(name):
        return
    launch_service(SESSION, {'server':'BE-api','client':'BE-member','app':'FE-macos','voice-worker':'GPT-Live-worker'}[name],
        command, env, pid_file(name))
    if name in SPECS:
        port = SPECS[name][0]
        for _ in range(400):
            try:
                call(port,'workspace')
                return
            except (OSError, urllib.error.HTTPError):
                time.sleep(.05)
        raise RuntimeError(f'{name} startup timeout; inspect Zellij {SESSION}')

def start(with_app, with_matrix=True):
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
    if with_matrix:
        if not running('matrix-gateway'):
            from matrix_stack import check_port
            check_port(8008)
        MATRIX.start()
        if not running('matrix-gateway'):
            MATRIX.gateway()
    start_media()
    for media in MEDIA if shutil.which('docker') else ():
        zellij_tab(SESSION,'LiveKit-'+media,['docker','logs','--follow',f'monastack-livekit-{media}'])
    spawn('server',[str(NODE)],environment('server', with_matrix))
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
    settings = dict(line.split('=', 1) for line in (RUNTIME/'.env').read_text().splitlines()
                    if '=' in line and not line.lstrip().startswith('#'))
    enabled = os.environ.get('LIVE_AGENTS_ENABLED', settings.get('LIVE_AGENTS_ENABLED', '0')).strip() == '1'
    if enabled:
        worker_python = RUNTIME/'live-agent/.venv/bin/python'
        if not worker_python.exists():
            raise RuntimeError('Run sh backend/live-agent/setup.sh first.')
        spawn('voice-worker', [str(worker_python), str(ROOT/'backend/live-agent/worker.py')], environment('server'))
        for _ in range(50):
            if running('voice-worker'): break
            time.sleep(.1)
        if not running('voice-worker'):
            raise RuntimeError('Voice worker exited; inspect runtime/logs/voice-worker.log')
    if with_app:
        if not APP.is_file():
            raise RuntimeError('Build app with flutter build macos --debug first; both nodes are running.')
        spawn('app',[str(APP)],environment('client'))
    status()

def status():
    MATRIX.status()
    print(f"Matrix clients: http://{SERVER_HOST}:8008; admin: loopback 8009; zellij attach {SESSION}")
    for name, (port, realtime, db, _) in SPECS.items():
        if not running(name):
            print(f'{name}: stopped')
            continue
        state = call(port,'workspace')
        print(f'{name}: PID {running(name)}, {state["role"]}, API 0.0.0.0:{port}, realtime {('0.0.0.0:'+str(realtime)) if name == 'server' else 'shared server :47831'}, DB {db}')
    for name, ports in MEDIA.items():
        if shutil.which('docker'):
            check = subprocess.run(['docker','inspect','--format','{{.State.Running}}',f'monastack-livekit-{name}'],capture_output=True,text=True)
            state = 'running' if check.returncode == 0 and check.stdout.strip() == 'true' else 'stopped'
        else:
            state = 'unavailable (Docker not installed)'
        print(f'LiveKit {name}: {state}; signaling :{ports[0]}, RTC TCP :{ports[1]}, UDP :{ports[2]}')
    print(f'Live agent worker: {running("voice-worker") or "stopped"}')
    if running('lan-client'): print(f'LAN client: running, PID {running("lan-client")}')
    print(f'app: {"running, PID "+str(running("app")) if running("app") else "stopped"}; connects to 127.0.0.1:47840')

def stop():
    for name in ['matrix-gateway','lan-client','app','voice-worker','client','server']:
        pid = running(name)
        if pid:
            os.kill(pid,signal.SIGTERM)
            print(f'{name}: stop requested')
            for _ in range(50):
                if not running(name): break
                time.sleep(.1)
        pid_file(name).unlink(missing_ok=True)
    MATRIX.stop()
    for name in MEDIA:
        if not media_owned(name): continue
        subprocess.run(['sh',str(ROOT/'backend/media/livekit-dev.sh'),'stop'],env=media_environment(name),check=True,capture_output=True)

if __name__ == '__main__':
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['start','status','stop'])
    parser.add_argument('--no-matrix',action='store_true',help='start office nodes without Matrix; Docker is optional')
    parser.add_argument('--no-app',action='store_true',help='start backend services without the macOS app')
    args = parser.parse_args()
    try:
        if args.action == 'start': start(not args.no_app, not args.no_matrix)
        elif args.action == 'stop': stop()
        else: status()
    except RuntimeError as error:
        raise SystemExit(str(error))
    except Exception as error:
        # Do not expose credentials, HTTP bodies or subprocess command input.
        raise SystemExit(f'Local office failed ({type(error).__name__}). Inspect Zellij monastack-matrix-server and occupied ports.')
