"""Real Synapse + Postgres and disposable authority/member, two Matrix clients.

Uses fixed product ports; refuses occupied ports. Services run visibly in Zellij.
Runtime evidence is retained under runtime/matrix-http; only test-owned services
are stopped. No requests are sent to a configured LAN server.
"""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'tools'))
from matrix_stack import Stack, check_port, zellij_tab
from visible_service import launch_service

NODE=ROOT/'backend/office-node/target/debug/monastack-office-node'
RUNTIME=ROOT/'runtime'/('matrix-http-'+secrets.token_hex(4))
SESSION='monastack-matrix-http'
OPENER=urllib.request.build_opener(urllib.request.ProxyHandler({}))
TOKENS={a:secrets.token_hex(32) for a in ('an','van','mai','mona')}
ENV_SENTINEL=secrets.token_hex(32)
ALL_SECRETS=[*TOKENS.values(),ENV_SENTINEL]
PIDS=[]
checks=0

def expect(condition, label):
    global checks
    assert condition,label
    checks+=1
    print('PASS '+label,flush=True)

def request(port, method, path, body=None, token=None, raw=False):
    data=body if isinstance(body,bytes) else None if body is None else json.dumps(body).encode()
    req=urllib.request.Request(f'http://127.0.0.1:{port}{path}',method=method,data=data,
        headers={'Content-Type':'application/octet-stream' if isinstance(body,bytes) else 'application/json',**({'Authorization':'Bearer '+token} if token else {})})
    try:
        with OPENER.open(req,timeout=65) as response:
            content=response.read()
            return response.status, content if raw else json.loads(content) if content else None
    except urllib.error.HTTPError as error:
        content=error.read()
        try: value=json.loads(content)
        except ValueError: value=content.decode()
        return error.code,value

def node(actor, method, path, body=None, port=47830):
    return request(port,method,'/v1/'+path,body,TOKENS[actor])

def mx(actor, method, path, body=None, version='v3', raw=False):
    return request(8008,method,f'/_matrix/client/{version}/'+path,body,MATRIX_TOKENS[actor],raw)

def env(db):
    return {**os.environ,'MONASTACK_RUNTIME_DIR':str(RUNTIME),'MONASTACK_DB':str(db),
        'MONASTACK_REALTIME':'off','MONASTACK_SEED_COMPANY':'0','MONASTACK_BIND_HOST':'127.0.0.1',
        'MONASTACK_MATRIX_DIR':str(RUNTIME/'matrix'),'MONASTACK_MATRIX_PUBLIC_URL':'http://127.0.0.1:8008','MONASTACK_TEST_SECRET':ENV_SENTINEL}

def visible(name, database, port):
    pidfile=RUNTIME/'pids'/f'{name}.pid'
    values=env(database)
    values['MONASTACK_NODE_PORT']=str(port)
    launch_service(SESSION,name,[str(NODE)],values,pidfile)
    for _ in range(300):
        try:
            if request(port,'GET','/v1/workspace')[0]==200:
                PIDS.append(pidfile)
                return
        except OSError: time.sleep(.1)
    raise RuntimeError('test node not ready; inspect '+name)

def stop_node(name):
    path=RUNTIME/'pids'/f'{name}.pid'
    if path.exists():
        os.kill(int(path.read_text()),signal.SIGTERM)
        for _ in range(100):
            try: os.kill(int(path.read_text()),0)
            except ProcessLookupError: break
            time.sleep(.05)

def wait_until(fn,label):
    for _ in range(150):
        try:
            if fn(): return
        except OSError:
            pass
        time.sleep(.1)
    raise AssertionError(label)

def signed(claims,secret):
    enc=lambda value:base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')
    body=enc({'alg':'HS256','typ':'JWT'})+'.'+enc(claims)
    signature=base64.urlsafe_b64encode(hmac.new(secret.encode(),body.encode(),hashlib.sha256).digest()).decode().rstrip('=')
    return body+'.'+signature

def room_path(room,tail):
    return 'rooms/'+urllib.parse.quote(room,safe='')+'/'+tail

if __name__=='__main__':
    os.umask(0o077)
    for port in (47830,47840,8008,8009): check_port(port)
    RUNTIME.mkdir(parents=True,mode=0o700)
    database=RUNTIME/'db/office.sqlite3'
    environment=env(database)
    for actor,token in TOKENS.items():
        if actor=='mona': continue
        subprocess.run([str(NODE),'enroll',actor],env=environment,input=token,text=True,check=True,capture_output=True)
    with sqlite3.connect(database) as conn:
        conn.execute('INSERT INTO tokens VALUES (?,?)',(hashlib.sha256(TOKENS['mona'].encode()).digest(),'mona'))
    # Authentic legacy data fixture, never replayed into Matrix.
    with sqlite3.connect(database) as conn:
        conn.executemany('INSERT INTO messages VALUES (?,?,?,?,?)',[
            ('legacy-old-lobby','room:lobby','an','earlier',100),
            ('legacy-new-lobby','room:lobby','van','later',200),
            ('legacy-finance','room:finance','van','private earlier',150),
            ('legacy-dm','dm:an:van','an','private dm',160)])
    stack=Stack(RUNTIME,name=RUNTIME.name,session=SESSION)
    MATRIX_TOKENS={}
    bridge=None
    try:
        bridge=stack.start()
        ALL_SECRETS += [bridge['admin_token'],bridge['jwt_secret']]
        expect(request(8009,'GET','/_synapse/admin/v1/server_version',token=bridge['admin_token'])[1]['server_version']=='1.164.1','running pinned Synapse 1.164.1')
        for suffix,source in [('postgres',RUNTIME/'matrix/postgres'),('synapse',RUNTIME/'matrix/synapse')]:
            spec=json.loads(stack.docker('inspect',stack.name+'-'+suffix,capture_output=True,text=True).stdout)[0]
            expect([m['Source'] for m in spec['Mounts']]==[str(source)],suffix+' mounts only its own directory')
        stack.gateway(bind='0.0.0.0')
        visible('BE-test',database,47830)
        with sqlite3.connect(database) as conn:
            backup=Path(conn.execute("SELECT value FROM metadata WHERE key='matrix-backup-v1'").fetchone()[0])
        expect(node('an','GET','chat/config')[1]=={'enabled':True,'homeserver_url':'http://127.0.0.1:8008','server_name':'monastack.local'},'advertised config contract')
        expect(request(8008,'GET','/_synapse/admin/v1/server_version',token=bridge['admin_token'])[0]==404,'public listener refuses admin even with admin token')
        # Make an actual LAN-address request to this computer, never the office
        # LAN server. The gateway binds all interfaces; the upstream does not.
        route=subprocess.run(['ipconfig','getifaddr','en0'],capture_output=True,text=True).stdout.strip()
        if not route:
            route=socket.gethostbyname(socket.gethostname())
        assert route!='192.168.224.217','refusing prohibited server address'
        req=urllib.request.Request(f'http://{route}:8008/_synapse/admin/v1/server_version',headers={'Authorization':'Bearer '+bridge['admin_token']})
        try:
            OPENER.open(req,timeout=5)
            raise AssertionError('LAN exposed admin')
        except urllib.error.HTTPError as error:
            expect(error.code==404,'LAN address refuses admin API')
        with socket.socket() as sock:
            expect(sock.connect_ex((route,8009))!=0,'Synapse admin port bound only to loopback')
        expect(request(8008,'GET','/_matrix/federation/v1/version')[0]==404,'federation routes blocked')
        expect(request(8008,'POST','/_matrix/client/v3/register',{'username':'outsider','password':'no-registration','auth':{'type':'m.login.dummy'}})[0]==403,'public registration disabled')
        expect(any(f['type']=='org.matrix.login.jwt' for f in request(8008,'GET','/_matrix/client/v3/login')[1]['flows']),'JWT login advertised')
        users={}
        sessions={}
        for actor in ('an','van','mai'):
            status,session=node(actor,'POST','chat/session',{'device_name':'HTTP test'})
            expect(status==200,'session bridge '+actor)
            sessions[actor]=session; ALL_SECRETS.append(session['login_token'])
            claims=json.loads(base64.urlsafe_b64decode(session['login_token'].split('.')[1]+'=='))
            expect(claims['exp']-claims['iat']==60 and claims['sub']==session['user_id'].split(':')[0][1:] and claims['iss']=='monastack-node' and claims['aud']=='monastack-matrix','JWT claims '+actor)
            status,login=request(8008,'POST','/_matrix/client/v3/login',{'type':'org.matrix.login.jwt','token':session['login_token'],'initial_device_display_name':'HTTP '+actor})
            expect(status==200,'real Synapse JWT login '+actor)
            MATRIX_TOKENS[actor]=login['access_token']; users[actor]=login['user_id']; ALL_SECRETS.append(login['access_token'])
        expect(node('an','POST','chat/session',{'device_name':'Again'})[1]['user_id']==users['an'],'repeat session reuses user')
        for changes,label in [({'exp':int(time.time())-120},'expired'),({'aud':'wrong'},'wrong audience'),({'iss':'wrong'},'wrong issuer')]:
            claims={'sub':users['an'].split(':')[0][1:],'aud':'monastack-matrix','iss':'monastack-node','exp':int(time.time())+60,**changes}
            token=signed(claims,bridge['jwt_secret']); ALL_SECRETS.append(token)
            expect(request(8008,'POST','/_matrix/client/v3/login',{'type':'org.matrix.login.jwt','token':token})[0]==403,label+' JWT rejected at client listener')
        token=sessions['an']['login_token']; parts=token.split('.'); parts[2]=('A' if parts[2][0]!='A' else 'B')+parts[2][1:]
        expect(request(8008,'POST','/_matrix/client/v3/login',{'type':'org.matrix.login.jwt','token':'.'.join(parts)})[0]==403,'tampered JWT rejected')
        claims={'sub':users['an'].split(':')[0][1:],'aud':'monastack-matrix','iss':'monastack-node','exp':int(time.time())-300}
        expired=signed(claims,bridge['jwt_secret'])
        expect(request(8009,'POST','/_matrix/client/v3/login',{'type':'org.matrix.login.jwt','token':expired})[0]==403,'Synapse refuses expiry beyond its built-in clock skew')
        expect(node('an','POST','chat/session',{}) == (400,'invalid device name'), 'missing device name uses node error shape')
        expect(node('mona','POST','chat/session',{'device_name':'Agent'})[0]==403,'agent refused')
        directory=node('an','GET','chat/users')[1]
        expect(not list((RUNTIME/'pids').glob('*.env.json')),'service launch environment files consumed')
        expect(all(u['kind']=='human' and u['user_id'].startswith('@u') for u in directory),'human directory provisioned')
        for payload in ('',bridge['admin_user']):
            found=mx('an','POST','user_directory/search',{'search_term':payload,'limit':100})
            expect(found[0]==200 and all(u['user_id'] in {person['user_id'] for person in directory} for u in found[1]['results']),'Matrix user directory excludes service identities')
        channels={actor:{r['office_room']:r for r in node(actor,'GET','chat/rooms')[1]} for actor in ('an','van')}
        lobby=channels['an']['lobby']['matrix_room_id']; finance=channels['van']['finance']['matrix_room_id']
        expect(lobby==channels['van']['lobby']['matrix_room_id'] and lobby!=finance,'shared stable distinct room mappings')
        power=mx('van','GET',room_path(finance,'state/m.room.power_levels'))[1]
        expect(all(power[key]==100 for key in ('invite','kick','ban','redact','state_default')),'node-owned room power levels enforced on Synapse 1.164.1')
        expect(request(8009,'POST','/_matrix/client/v3/'+room_path(finance,'invite'),{'user_id':users['an']},MATRIX_TOKENS['van'])[0]==403,'ordinary room members cannot invite an outsider')
        expect('finance' not in channels['an'] and channels['van']['finance']['restricted'],'explicit finance access only')
        encoded_finance=urllib.parse.quote(finance,safe='')
        unstable='/_matrix/client/unstable/org.matrix.msc3030/rooms/'+encoded_finance+'/timestamp_to_event?ts=0&dir=b'
        expect(request(8008,'GET',unstable,token=MATRIX_TOKENS['an'])[0]==403,'namespaced timestamp route denies outsider')
        expect(mx('van','GET',room_path(finance,'unknown_extension'))[0]==403,'unknown room shape refused even for authorized user')
        for payload in ([],None,42,'login'):
            expect(request(8008,'POST','/_matrix/client/v3/login',json.dumps(payload).encode())[0]==400,'non-object login returns 400 '+str(type(payload).__name__))
        marker='matrixmarker'+secrets.token_hex(6)
        status,event=mx('van','PUT',room_path(finance,'send/m.room.message/private1'),{'msgtype':'m.text','body':marker})
        expect(status==200,'restricted room post')
        for tail in ('join','messages?dir=b','state','members','event/'+urllib.parse.quote(event['event_id'],safe='')):
            method='POST' if tail=='join' else 'GET'
            expect(mx('an',method,room_path(finance,tail),{} if method=='POST' else None)[0]==403,'outsider denied '+tail.split('?')[0])
        search={'search_categories':{'room_events':{'search_term':marker}}}
        expect(mx('an','POST','search',search)[1]['search_categories']['room_events']['results']==[],'outsider cannot search finance')
        expect(mx('van','POST','search',search)[1]['search_categories']['room_events']['results'],'authorized full-history search')
        status,lobby_event=mx('an','PUT',room_path(lobby,'send/m.room.message/lobby1'),{'msgtype':'m.text','body':'shared persistent message'})
        expect(status==200,'shared room post')
        expect(mx('an','PUT',room_path(lobby,'send/m.room.message/lobby1'),{'msgtype':'m.text','body':'shared persistent message'})[1]['event_id']==lobby_event['event_id'],'Matrix transaction retry creates one event')
        sync=mx('van','GET','sync?timeout=0')[1]
        expect(any(e['event_id']==lobby_event['event_id'] for e in sync['rooms']['join'][lobby]['timeline']['events']),'second account receives message through sync')
        expect(not any(e.get('content',{}).get('body')==marker for e in sync['rooms']['join'][lobby]['timeline']['events']),'rooms do not mix')
        # Direct Matrix denial too, bypassing our policy gateway: join rules are
        # invite-only and node-owned power levels prohibit members inviting.
        expect(request(8009,'POST','/_matrix/client/v3/'+room_path(finance,'join'),{},MATRIX_TOKENS['an'])[0]==403,'Synapse itself denies unauthorized join')
        expect(request(8009,'GET','/_matrix/client/v3/'+room_path(finance,'messages?dir=b'),token=MATRIX_TOKENS['an'])[0]==403,'Synapse itself denies outsider history')
        # Grant/revoke goes through the existing office CLI + realtime epoch.
        subprocess.run([str(NODE),'room','grant','finance','an'],env=environment,check=True,capture_output=True)
        expect(any(r['office_room']=='finance' for r in node('an','GET','chat/rooms')[1]),'grant joins at Synapse')
        expect(not any(e.get('content',{}).get('body')==marker for e in mx('an','GET',room_path(finance,'messages?dir=b'))[1]['chunk']),'joined history hides pre-admission messages')
        status,admitted=mx('van','PUT',room_path(finance,'send/m.room.message/admitted'),{'msgtype':'m.text','body':marker+' admitted'})
        expect(status==200 and mx('an','GET',room_path(finance,'event/'+urllib.parse.quote(admitted['event_id'],safe='')))[0]==200,'admitted member reads new event')
        before=mx('an','GET','sync?timeout=0')[1]['next_batch']
        subprocess.run([str(NODE),'room','revoke','finance','an'],env=environment,check=True,capture_output=True)
        wait_until(lambda:finance not in request(8009,'GET','/_matrix/client/v3/joined_rooms',token=MATRIX_TOKENS['an'])[1]['joined_rooms'],'kick not reconciled')
        left=mx('an','GET','sync?timeout=0&since='+urllib.parse.quote(before))[1]
        expect(all(key not in left.get('rooms',{}).get('leave',{}).get(finance,{}) for key in ('state','ephemeral','account_data')),'revoked sync strips state ephemeral and account data')
        expect(finance in left.get('rooms',{}).get('leave',{}),'next sync delivers kick leave')
        expect('finance' not in {r['office_room'] for r in node('an','GET','chat/rooms')[1]},'revoked room immediately absent from node')
        expect(mx('an','GET',room_path(finance,'messages?dir=b'))[0]==403,'gateway refuses previously admitted history after revoke')
        expect(mx('an','POST','search',search)[1]['search_categories']['room_events']['results']==[],'revoked search excludes old readable events')
        expect(mx('an','PUT',room_path(finance,'send/m.room.message/revoked'),{'msgtype':'m.text','body':'refused'})[0]==403,'revoked send denied')
        # Media limitation is explicitly tested: authentication, not membership.
        status,upload=request(8008,'POST','/_matrix/media/v3/upload?filename=test.txt',b'synthetic attachment',MATRIX_TOKENS['van'])
        expect(status==200,'authenticated media upload')
        host,media=upload['content_uri'][6:].split('/',1)
        media_path='media/download/'+host+'/'+media
        expect(mx('an','GET',media_path,version='v1',raw=True)[0]==200,'documented known-mxc media remains readable after revoke')
        expect(request(8008,'GET',f'/_matrix/media/v3/download/{host}/{media}')[0]==404,'unauthenticated media refused')
        dm=node('an','POST','chat/dms',{'actors':['van']})[1]
        expect(dm['created'] and node('van','POST','chat/dms',{'actors':['an']})[1]=={'matrix_room_id':dm['matrix_room_id'],'created':False},'one-to-one DM member-set reuse')
        group=node('an','POST','chat/dms',{'actors':['van','mai']})[1]
        expect(group['created'] and node('mai','POST','chat/dms',{'actors':['van','an']})[1]['matrix_room_id']==group['matrix_room_id'],'group DM canonical reuse')
        expect(mx('mai','GET',room_path(dm['matrix_room_id'],'messages?dir=b'))[0]==403,'DM outsider history denied')
        expect(mx('an','PUT',room_path(dm['matrix_room_id'],'send/m.room.message/dm1'),{'msgtype':'m.text','body':'private DM'})[0]==200,'DM message sends')
        expect(any(e.get('content',{}).get('body')=='private DM' for e in mx('van','GET',room_path(dm['matrix_room_id'],'messages?dir=b'))[1]['chunk']),'second DM user reads')
        legacy=node('an','GET','chat/legacy/room%3Alobby?limit=1')[1]
        expect(legacy[0]['id']=='legacy-new-lobby' and 'sender_name' in legacy[0] and 'sender_actor' in legacy[0],'legacy newest-first fields and limit')
        expect(node('an','GET','chat/legacy/room%3Alobby?before=200')[1][0]['id']=='legacy-old-lobby','legacy timestamp pagination')
        expect(node('an','GET','chat/legacy/room%3Afinance')[0]==403,'legacy revocation enforced')
        expect(node('van','GET','chat/legacy/dm%3Aan')[1][0]['id']=='legacy-dm','legacy DM scope access')
        expect(node('an','GET','chat/legacy/dm%3Aan%3Avan')[1][0]['id']=='legacy-dm','canonical legacy DM scope accepted')
        expect(node('mai','GET','chat/legacy/dm%3Aan%3Avan')[0]==403,'legacy DM outsider refused')
        expect(node('an','POST','messages/room%3Alobby',{'id':'retired','body':'not written'})[0]==404,'old write endpoint removed')
        with sqlite3.connect(backup) as conn:
            expect(conn.execute('SELECT COUNT(*) FROM messages').fetchone()[0]==4,'pre-Matrix backup preserves legacy data')
        # A failed Synapse operation remains pending and is repaired on retry.
        stack.docker('stop',stack.name+'-synapse',stdout=subprocess.DEVNULL)
        subprocess.run([str(NODE),'room','revoke','finance','van'],env=environment,check=True,capture_output=True)
        expect(node('van','GET','chat/legacy/room%3Afinance')[0]==403,'office denial immediate while Synapse is offline')
        expect(node('van','GET','chat/rooms')[0]==503,'Synapse outage is explicit, never fake success')
        stack.start()
        wait_until(lambda:finance not in request(8009,'GET','/_matrix/client/v3/joined_rooms',token=MATRIX_TOKENS['van'])[1]['joined_rooms'],'offline revoke not retried')
        expect(True,'epoch reconciliation repairs offline revocation')
        with sqlite3.connect(database) as conn:
            counts=[conn.execute('SELECT COUNT(*) FROM '+table).fetchone()[0] for table in ('matrix_users','matrix_rooms','matrix_dms')]
            mapping=conn.execute('SELECT office_room,room_id FROM matrix_rooms ORDER BY office_room').fetchall()
            # Simulate a crash after Synapse created a room, before DB recorded
            # its room_id: the reserved alias must recover the same object.
            conn.execute("UPDATE matrix_rooms SET room_id=NULL WHERE office_room='lobby'")
            conn.execute("INSERT INTO matrix_intents VALUES ('crash-injection',0,0)")
            conn.execute("UPDATE matrix_room_details SET name='Renamed lobby',topic='Renamed topic' WHERE office_room='lobby'")
        stop_node('BE-test')
        stack.stop()
        bridge=stack.start()
        stack.gateway(bind='0.0.0.0')
        visible('BE-test',database,47830)
        after=node('an','GET','chat/rooms')[1]
        expect(next(r for r in after if r['office_room']=='lobby')['matrix_room_id']==lobby,'crash recovery reuses alias and room ID')
        expect(next(r for r in after if r['office_room']=='lobby')['name']=='Renamed lobby','rename preserves mapping')
        expect(any(e.get('event_id')==lobby_event['event_id'] for e in mx('an','GET',room_path(lobby,'messages?dir=b'))[1]['chunk']),'node and Synapse restart preserve history')
        expect(node('an','POST','chat/session',{'device_name':'Restart'})[1]['user_id']==users['an'],'restart preserves actor mapping')
        expect(node('van','POST','chat/dms',{'actors':['an']})[1]['matrix_room_id']==dm['matrix_room_id'],'restart preserves DM mapping')
        expect(len(list((RUNTIME/'backups').glob('before-matrix-*.sqlite3')))==1,'node alone checkpoints exactly one pre-Matrix backup')
        with sqlite3.connect(database) as conn:
            expect(counts==[conn.execute('SELECT COUNT(*) FROM '+table).fetchone()[0] for table in ('matrix_users','matrix_rooms','matrix_dms')],'restart creates no duplicate maps')
            expect(mapping==conn.execute('SELECT office_room,room_id FROM matrix_rooms ORDER BY office_room').fetchall(),'all mappings stable')
            expect(conn.execute('SELECT COUNT(*) FROM matrix_intents WHERE done=0').fetchone()[0]==0,'pending intents reconciled')
        rooms_remote=request(8009,'GET','/_synapse/admin/v1/rooms?limit=100',token=bridge['admin_token'])[1]['rooms']
        expect(len(rooms_remote)==counts[1]+counts[2],'real Synapse room count proves no orphan duplicates')
        users_remote=request(8009,'GET','/_synapse/admin/v2/users?limit=100',token=bridge['admin_token'])[1]['users']
        expect(len(users_remote)==counts[0]+1,'real Synapse users prove no duplicate accounts')
        # Disabled accounts cannot mint sessions; their Matrix devices end.
        with sqlite3.connect(database) as conn:
            conn.execute("INSERT INTO accounts(actor,username,created,disabled) VALUES ('mai','test-disabled',0,1)")
            conn.execute("UPDATE metadata SET value=CAST(value AS INTEGER)+1 WHERE key='realtime_epoch'")
        expect(node('mai','POST','chat/session',{'device_name':'Disabled'})[0]==403,'disabled legacy bearer refused')
        wait_until(lambda:mx('mai','GET','account/whoami')[0]==401,'disabled Matrix token remained valid')
        wait_until(lambda:request(8009,'GET','/_synapse/admin/v2/users/'+urllib.parse.quote(users['mai'],safe=''),token=bridge['admin_token'])[1]['deactivated'],'disabled user was not deactivated')
        expect(all(u['user_id']!=users['mai'] for u in mx('an','POST','user_directory/search',{'search_term':users['mai'],'limit':100})[1]['results']),'Matrix directory excludes disabled humans')
        expect(True,'disabled Matrix device revoked via epoch')
        with sqlite3.connect(database) as conn:
            conn.execute("UPDATE accounts SET disabled=0 WHERE actor='mai'")
            conn.execute("UPDATE metadata SET value=CAST(value AS INTEGER)+1 WHERE key='realtime_epoch'")
        status,reactivated=node('mai','POST','chat/session',{'device_name':'Enabled again'})
        expect(status==200 and reactivated['user_id']==users['mai'],'re-enabled account keeps its Matrix identity')
        expect(request(8008,'POST','/_matrix/client/v3/login',{'type':'org.matrix.login.jwt','token':reactivated['login_token']})[0]==200,'real Synapse accepts reactivated user login')
        # Exercise signed Monastack session revocation using the real auth API.
        stop_node('BE-test')
        seeded={**environment,'MONASTACK_SEED_COMPANY':'1'}
        environment=seeded
        # visible reads env(), so seed once by invoking the server with the
        # seed flag through its own visible pane, then normal service behavior.
        launch_service(SESSION,'BE-test',[str(NODE)],{**seeded,'MONASTACK_NODE_PORT':'47830'},RUNTIME/'pids/BE-test.pid')
        wait_until(lambda:request(47830,'POST','/v1/auth/login',{'username':'triet.le','password':'NviaiSeaxOpenAIHackathon','device':'HTTP','platform':'test'})[0]==200,'seeded auth did not start')
        login=request(47830,'POST','/v1/auth/login',{'username':'triet.le','password':'NviaiSeaxOpenAIHackathon','device':'HTTP','platform':'test'})[1]
        access=login['access_token']; ALL_SECRETS.append(access)
        join=request(47830,'POST','/v1/admin/nodes',{'name':'Matrix member test'},access)[1]
        memberdb=RUNTIME/'db/member.sqlite3'
        memberenv={**env(memberdb),'MONASTACK_WORKSPACE_MODE':'shared'}
        memberenv.pop('MONASTACK_MATRIX_DIR',None)
        subprocess.run([str(NODE),'setup-code'],env=memberenv,check=True,capture_output=True)
        subprocess.run([str(NODE),'join','http://127.0.0.1:47830'],env=memberenv,input=join['code'],text=True,check=True,capture_output=True)
        visible('BE-member-test',memberdb,47840)
        expect(request(47840,'GET','/v1/chat/config',token=access)[1]==node('an','GET','chat/config')[1],'member forwards Matrix configuration')
        direct=request(47830,'POST','/v1/chat/session',{'device_name':'Master'},access)
        forwarded=request(47840,'POST','/v1/chat/session',{'device_name':'Member'},access)
        expect(direct[0]==forwarded[0]==200 and direct[1]['user_id']==forwarded[1]['user_id'],'member reuses master Matrix identity')
        with sqlite3.connect(memberdb) as conn:
            expect(conn.execute('SELECT COUNT(*) FROM matrix_users').fetchone()[0]==0,'member provisions no independent Matrix users')
        matrix_devices=[]
        ALL_SECRETS += [direct['login_token'],forwarded['login_token']]
        for device in ('signed-office-a','signed-office-b'):
            status,device_login=request(8008,'POST','/_matrix/client/v3/login',{'type':'org.matrix.login.jwt','token':direct['login_token'],'device_id':device})
            expect(status==200,'signed office actor Matrix device '+device)
            matrix_devices.append(device_login['access_token'])
            ALL_SECRETS.append(device_login['access_token'])
        expect(request(47830,'POST','/v1/auth/logout',token=access)[0]==204,'Monastack session signed out')
        expect(request(47830,'POST','/v1/chat/session',{'device_name':'Revoked'},access)[0]==401,'revoked Monastack session refused')
        wait_until(lambda:all(request(8009,'GET','/_matrix/client/v3/account/whoami',token=token)[0]==401 for token in matrix_devices),'actor-wide sign-out did not revoke both Matrix devices')
        expect(True,'documented actor-wide Matrix device sign-out enforced')
        # Logs are inspected without printing their contents or the secrets.
        logs=b''
        for suffix in ('synapse','postgres'):
            logs+=subprocess.run(['docker','logs',stack.name+'-'+suffix],capture_output=True).stdout
            logs+=subprocess.run(['docker','logs',stack.name+'-'+suffix],capture_output=True).stderr
        panes=json.loads(subprocess.run(['zellij','--session',SESSION,'action','list-panes','--all','--json'],capture_output=True,text=True,check=True).stdout)
        expect(all(secret not in json.dumps(panes) for secret in ALL_SECRETS),'Zellij pane metadata contains no issued secrets')
        for pidfile in (RUNTIME/'pids').glob('*.pid'):
            argv=subprocess.run(['ps','-p',pidfile.read_text().strip(),'-o','command='],capture_output=True,text=True).stdout
            expect(all(secret not in argv for secret in ALL_SECRETS),'service argv contains no issued secrets '+pidfile.stem)
        for pane in panes:
            if pane.get('is_plugin'): continue
            target=RUNTIME/(f'pane-{pane["id"]}.log')
            subprocess.run(['zellij','--session',SESSION,'action','dump-screen','--pane-id',str(pane['id']),'--full','--path',str(target)],check=True,capture_output=True)
            logs+=target.read_bytes()
        (RUNTIME/'service-test.log').write_bytes(logs)
        expect(all(secret.encode() not in logs for secret in ALL_SECRETS),'token and JWT grep of service logs clean')
        expect(all(p.stat().st_mode&0o777==0o600 for p in (RUNTIME/'matrix').iterdir() if p.is_file()),'runtime credential/config files are 0600')
        print(f'Matrix HTTP: {checks} checks passed. Evidence: {RUNTIME}',flush=True)
    except BaseException:
        panes=json.loads(subprocess.run(['zellij','--session',SESSION,'action','list-panes','--all','--json'],capture_output=True,text=True,check=True).stdout)
        for pane in panes:
            if pane.get('is_plugin'): continue
            subprocess.run(['zellij','--session',SESSION,'action','dump-screen','--pane-id',str(pane['id']),'--full','--path',str(RUNTIME/f'failure-pane-{pane["id"]}.log')],capture_output=True)
        print('Failure evidence: '+str(RUNTIME),flush=True)
        raise
    finally:
        for name in ('BE-test','BE-member-test'): 
            try: stop_node(name)
            except ProcessLookupError: pass
        gateway=RUNTIME/'pids/matrix-gateway.pid'
        if gateway.exists():
            try: os.kill(int(gateway.read_text()),signal.SIGTERM)
            except ProcessLookupError: pass
        stack.stop()
