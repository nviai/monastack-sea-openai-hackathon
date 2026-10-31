"""Pinned, private Synapse/Postgres lifecycle used by local_office and HTTP tests."""
import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
# Synapse v1.164.1 and Postgres 17.6 bookworm, multi-architecture index digests.
# Version labels are retained alongside immutable references for auditability.
SYNAPSE = 'matrixdotorg/synapse:v1.164.1@sha256:fa4aa980f279bcf26d4e7ecc2a2c9a701c73f2ebe8841da9bdcf3b2fdf693d75'
POSTGRES = 'postgres:17.6-bookworm@sha256:f3bd19c606e442c3d7bdfa8002e03fe260a1023351e0ea4598032022b68dd6e3'

def run(*args, **kwargs):
    return subprocess.run(list(args), check=True, **kwargs)

def api(port, path, body=None, token=None, method=None):
    request = urllib.request.Request(f'http://127.0.0.1:{port}{path}',
        data=None if body is None else json.dumps(body).encode(), method=method,
        headers={'Content-Type': 'application/json', **({'Authorization': 'Bearer '+token} if token else {})})
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=20) as response:
        return json.load(response)

def registration_conflict(error):
    if error.code != 400:
        return False
    try:
        failure = json.loads(error.read())
    except ValueError:
        return False
    return isinstance(failure, dict) and failure.get('error') == 'User ID already taken.'


def check_port(port):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        try:
            sock.bind(('0.0.0.0', port))
        except OSError:
            raise RuntimeError(f'Port {port} is occupied; service left untouched')

from visible_service import launch_service, write_private, zellij_tab

class Stack:
    def __init__(self, runtime=None, name='monastack-matrix-server', admin_port=8009, session='monastack-matrix-server'):
        self.runtime = Path(runtime or os.environ.get('MONASTACK_RUNTIME_DIR', ROOT/'runtime')).resolve()
        self.directory = self.runtime/'matrix'
        self.name = name
        self.admin_port = admin_port
        self.session = session

    def docker(self, *args, **kwargs):
        return run('docker', *args, **kwargs)

    def running(self, suffix):
        if not shutil.which('docker'): return False
        result = subprocess.run(['docker','inspect','--format','{{.State.Running}}',self.name+'-'+suffix],capture_output=True,text=True)
        return result.returncode == 0 and result.stdout.strip() == 'true'

    def owned(self, suffix):
        if not shutil.which('docker'): return False
        result = subprocess.run(['docker','inspect','--format','{{index .Config.Labels "monastack.matrix.runtime"}}',self.name+'-'+suffix],capture_output=True,text=True)
        if result.returncode == 0 and result.stdout.strip() != str(self.directory):
            raise RuntimeError(f'Container {self.name}-{suffix} belongs to another runtime')
        return result.returncode == 0

    def prepare(self):
        if (self.directory/'homeserver.signing.key').exists() and self.running('synapse'):
            raise RuntimeError('Stop this Matrix stack before migrating its container mounts')
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        secrets_path = self.directory/'secrets.json'
        if secrets_path.exists():
            settings = json.loads(secrets_path.read_text())
        else:
            settings = {k: secrets.token_hex(32) for k in ('jwt_secret','registration_secret','postgres_password','admin_password','macaroon_secret')}
            settings.update(server_name='monastack.local', admin_localpart='svc'+secrets.token_hex(12))
            write_private(secrets_path,json.dumps(settings))
        self.synapse = self.directory/'synapse'
        self.synapse.mkdir(exist_ok=True, mode=0o700)
        (self.directory/'postgres').mkdir(exist_ok=True, mode=0o700)
        # Preserve existing data when adopting the narrower container mounts.
        for name in ('homeserver.signing.key','media_store'):
            old = self.directory/name
            if old.exists() and not (self.synapse/name).exists():
                old.rename(self.synapse/name)
        write_private(self.directory/'postgres.env',f'POSTGRES_USER=synapse\nPOSTGRES_DB=synapse\nPOSTGRES_PASSWORD={settings["postgres_password"]}\nPOSTGRES_INITDB_ARGS=--encoding=UTF8 --locale=C\n')
        # JSON is YAML, avoiding a host YAML dependency. Files are 0600; run as
        # root inside this local container to read the bind mount on macOS.
        config = dict(server_name=settings['server_name'], report_stats=False,
            signing_key_path='/data/homeserver.signing.key', media_store_path='/data/media_store',
            pid_file='/data/homeserver.pid', log_config='/data/log.config',
            listeners=[dict(port=8008,type='http',tls=False,bind_addresses=['0.0.0.0'],resources=[dict(names=['client'],compress=False)])],
            database=dict(name='psycopg2',args=dict(user='synapse',password=settings['postgres_password'],database='synapse',host=self.name+'-postgres',port=5432,cp_min=2,cp_max=5)),
            enable_registration=False, registration_shared_secret=settings['registration_secret'],
            macaroon_secret_key=settings['macaroon_secret'],
            jwt_config=dict(enabled=True,secret=settings['jwt_secret'],algorithm='HS256',issuer='monastack-node',audiences=['monastack-matrix']),
            federation_domain_whitelist=[],federation_sender_instances=[],send_federation=False,
            trusted_key_servers=[],url_preview_enabled=False,enable_authenticated_media=True,
            allow_public_rooms_without_auth=False,allow_public_rooms_over_federation=False,
            suppress_key_server_warning=True,enable_search=True, max_upload_size='50M',
            password_config=dict(enabled=False),
            rc_login=dict(address=dict(per_second=1,burst_count=20),account=dict(per_second=1,burst_count=20)))
        write_private(self.synapse/'homeserver.yaml', json.dumps(config,indent=2))
        write_private(self.synapse/'log.config', json.dumps(dict(version=1,formatters=dict(simple=dict(format='%(asctime)s %(levelname)s %(name)s: %(message)s')),handlers=dict(console=dict(**{'class':'logging.StreamHandler'},formatter='simple')),root=dict(level='WARNING',handlers=['console']),disable_existing_loggers=False)))
        return settings

    def start(self):
        if not shutil.which('docker'):
            raise RuntimeError('Matrix requires Docker; use local_office.py start --no-matrix')
        settings = self.prepare()
        if not self.running('synapse'):
            check_port(self.admin_port)
        net = self.name+'-private'
        check = subprocess.run(['docker','network','inspect',net],capture_output=True)
        if check.returncode:
            self.docker('network','create',net,stdout=subprocess.DEVNULL)
        for suffix in ('postgres','synapse'):
            if self.owned(suffix):
                spec = json.loads(self.docker('inspect',self.name+'-'+suffix,capture_output=True,text=True).stdout)[0]
                expected_image = POSTGRES if suffix == 'postgres' else SYNAPSE
                expected_source = str(self.directory/'postgres' if suffix == 'postgres' else self.synapse)
                if spec['Config']['Image'] != expected_image or not any(m['Source']==expected_source for m in spec['Mounts']):
                    if self.running(suffix):
                        raise RuntimeError('Stop this Matrix stack before upgrading its image or mounts')
                    self.docker('rm',self.name+'-'+suffix,stdout=subprocess.DEVNULL)
            if self.owned(suffix):
                if not self.running(suffix): self.docker('start',self.name+'-'+suffix,stdout=subprocess.DEVNULL)
            elif suffix == 'postgres':
                self.docker('run','-d','--name',self.name+'-'+suffix,'--label','monastack.matrix.runtime='+str(self.directory),
                    '--network',net,'--env-file',str(self.directory/'postgres.env'),
                    '--mount',f"type=bind,source={self.directory / 'postgres'},target=/var/lib/postgresql/data",
                    '-e','PGDATA=/var/lib/postgresql/data',POSTGRES,stdout=subprocess.DEVNULL)
            else:
                self.docker('run','-d','--name',self.name+'-'+suffix,'--label','monastack.matrix.runtime='+str(self.directory),
                    '--network',net,'--user','0:0','-e','SYNAPSE_CONFIG_PATH=/data/homeserver.yaml',
                    '-p',f'127.0.0.1:{self.admin_port}:8008','--mount',f'type=bind,source={self.synapse},target=/data',
                    SYNAPSE,stdout=subprocess.DEVNULL)
            if suffix == 'postgres':
                for _ in range(120):
                    ready=subprocess.run(['docker','exec',self.name+'-postgres','pg_isready','-U','synapse'],capture_output=True)
                    if ready.returncode==0: break
                    time.sleep(.5)
                else: raise RuntimeError('Postgres did not start')
            zellij_tab(self.session,'Matrix-'+suffix,['docker','logs','--follow',self.name+'-'+suffix])
        for _ in range(180):
            try:
                api(self.admin_port,'/_matrix/client/versions')
                break
            except (OSError,ValueError): time.sleep(.5)
        else: raise RuntimeError('Synapse did not start; inspect Matrix-synapse tab')
        self.docker('exec','--user','0',self.name+'-synapse','chmod','600','/data/homeserver.signing.key')
        bridge_file=self.directory/'bridge.json'
        if not bridge_file.exists():
            nonce=api(self.admin_port,'/_synapse/admin/v1/register')['nonce']
            user=settings['admin_localpart']; password=settings['admin_password']
            mac=hmac.new(settings['registration_secret'].encode(), '\0'.join([nonce,user,password,'admin']).encode(),hashlib.sha1).hexdigest()
            # Shared-secret registration is idempotent via existing-user recovery.
            try:
                result=api(self.admin_port,'/_synapse/admin/v1/register',dict(nonce=nonce,username=user,password=password,admin=True,mac=mac))
                token=result['access_token']
            except urllib.error.HTTPError as error:
                if not registration_conflict(error): raise
                # Password login is deliberately disabled publicly; recover by
                # obtaining a token using the JWT path for this reserved admin.
                token=None
            if not token:
                import base64
                enc=lambda x:base64.urlsafe_b64encode(json.dumps(x).encode()).decode().rstrip('=')
                body=enc(dict(alg='HS256',typ='JWT'))+'.'+enc(dict(sub=user,iss='monastack-node',aud='monastack-matrix',exp=int(time.time())+60))
                sig=base64.urlsafe_b64encode(hmac.new(settings['jwt_secret'].encode(),body.encode(),hashlib.sha256).digest()).decode().rstrip('=')
                token=api(self.admin_port,'/_matrix/client/v3/login',dict(type='org.matrix.login.jwt',token=body+'.'+sig))['access_token']
            write_private(bridge_file,json.dumps(dict(server_name=settings['server_name'],admin_user=f'@{user}:{settings["server_name"]}',admin_token=token,jwt_secret=settings['jwt_secret'],admin_url=f'http://127.0.0.1:{self.admin_port}')))
        bridge=json.loads(bridge_file.read_text())
        # A homeserver admin is NOT automatically exempt from client rate limits.
        from urllib.parse import quote
        api(self.admin_port,'/_synapse/admin/v1/users/'+quote(bridge['admin_user'],safe='')+'/override_ratelimit',dict(messages_per_second=0,burst_count=0),bridge['admin_token'])
        return bridge

    def gateway(self, port=8008, bind='0.0.0.0'):
        check_port(port)
        (self.runtime/'pids').mkdir(parents=True,exist_ok=True,mode=0o700)
        environment = {**os.environ, 'MONASTACK_RUNTIME_DIR':str(self.runtime),
            'MONASTACK_MATRIX_DIR':str(self.directory),
            'MONASTACK_MATRIX_AUTHORITY_URL':os.environ.get('MONASTACK_MATRIX_AUTHORITY_URL','http://127.0.0.1:47830'),
            'MONASTACK_MATRIX_ADMIN_PORT':str(self.admin_port),'MONASTACK_MATRIX_PORT':str(port),
            'MONASTACK_MATRIX_BIND_HOST':bind}
        launch_service(self.session, 'Matrix-client', [sys.executable, ROOT/'tools/matrix_proxy.py'],
            environment, self.runtime/'pids/matrix-gateway.pid')
        for _ in range(100):
            try:
                api(port,'/_matrix/client/versions')
                return
            except OSError: time.sleep(.1)
        raise RuntimeError('Matrix gateway did not start')

    def status(self):
        if not shutil.which('docker'):
            print('Matrix: unavailable (Docker not installed)')
            return
        for suffix in ('postgres','synapse'):
            self.owned(suffix)
            print(f'Matrix {suffix}: {"running" if self.running(suffix) else "stopped"}; data {self.directory}')

    def stop(self):
        pidfile=self.runtime/'pids/matrix-gateway.pid'
        if pidfile.exists():
            pid=int(pidfile.read_text())
            process=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True).stdout
            if str(ROOT/'tools/matrix_proxy.py') in process:
                import signal
                os.kill(pid,signal.SIGTERM)
            pidfile.unlink(missing_ok=True)
        for suffix in ('synapse','postgres'):
            if self.owned(suffix) and self.running(suffix): self.docker('stop',self.name+'-'+suffix,stdout=subprocess.DEVNULL)

if __name__ == '__main__':
    os.umask(0o077)
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['start','stop','status'])
    args=parser.parse_args()
    stack=Stack()
    if args.action=='start': stack.start(); stack.gateway()
    elif args.action=='stop': stack.stop()
    else: stack.status()
