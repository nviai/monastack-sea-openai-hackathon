"""Client-only gateway with current office policy, including history revocation.

Synapse is loopback only. Each authenticated request resolves its Matrix user
and asks the node's existing policy; sync/search/notifications are checked again
AFTER a long poll. No request, token, URL or content is logged.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import base64
import hashlib
import hmac
import time
import ipaddress
import json
import os
import re
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request

HOP = {'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
       'te', 'trailer', 'transfer-encoding', 'upgrade', 'accept-encoding'}
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

# Room-scoped routes are deliberately enumerated. New Matrix extensions must
# be reviewed before public ingress can expose them. Every decoded identifier,
# even one in a state key or an extension namespace, also needs current access.
ROOM_ROUTE = re.compile(
    r"/_matrix/client/(?:r0|v3|v1)/rooms/[^/]+/(?:"
    r"(?:join|leave|forget|messages|members|joined_members|read_markers|typing/[^/]+|"
    r"timestamp_to_event|threads|hierarchy)|"
    r"(?:event|context)/[^/]+|"
    r"state(?:/[^/]+(?:/[^/]*)?)?|"
    r"(?:send|redact|receipt)/[^/]+/[^/]+|"
    r"relations/[^/]+(?:/[^/]+(?:/[^/]+)?)?)"
)
NAMESPACED_ROOM_ROUTE = re.compile(
    r"/_matrix/client/unstable/org\.matrix\.msc3030/rooms/[^/]+/timestamp_to_event"
)


def room_access(path, allowed):
    parts = path.split('/')
    identifiers = {part for part in parts if part.startswith(('!', '#'))}
    if not identifiers.issubset(allowed):
        return False
    # Refuse unknown room-shaped endpoints even if the caller can access the
    # embedded room. Detect room markers anywhere in an unstable namespace.
    if any(part in ('rooms', 'room', 'join', 'knock') for part in parts[4:]) or identifiers:
        return bool(
            ROOM_ROUTE.fullmatch(path)
            or NAMESPACED_ROOM_ROUTE.fullmatch(path)
            or re.fullmatch(r"/_matrix/client/(?:r0|v3)/join/[^/]+", path)
            or re.fullmatch(r"/_matrix/client/(?:r0|v3)/directory/room/[^/]+", path)
            or re.fullmatch(r"/_matrix/client/(?:r0|v3)/user/[^/]+/account_data/m\.fully_read/[^/]+", path)
            or re.fullmatch(r"/_matrix/client/(?:r0|v3)/user/[^/]+/rooms/[^/]+/account_data/[^/]+", path)
        ) and bool(identifiers)
    return True


def strip_revoked_sync(value, rooms):
    for category in ('join', 'invite', 'knock'):
        items = value.get('rooms', {}).get(category, {})
        value.setdefault('rooms', {})[category] = {k:v for k,v in items.items() if k in rooms}
    for key, item in value.get('rooms', {}).get('leave', {}).items():
        if key not in rooms:
            timeline = item.get('timeline', {})
            timeline['events'] = [event for event in timeline.get('events', [])
                if event.get('type') == 'm.room.member'
                and event.get('content', {}).get('membership') in ('leave', 'ban')]
            item.pop('state', None)
            item.pop('ephemeral', None)
            item.pop('account_data', None)


class ClientOnly(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def result(self, status, value):
        content=json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(content)))
        self.send_header('Connection','close')
        self.end_headers()
        self.wfile.write(content)
        self.close_connection=True

    def authorization_policy(self, authorization):
        port=int(os.environ.get('MONASTACK_MATRIX_ADMIN_PORT','8009'))
        request=urllib.request.Request(f'http://127.0.0.1:{port}/_matrix/client/v3/account/whoami',headers={'Authorization':authorization})
        with OPENER.open(request,timeout=10) as response:
            user=json.load(response)['user_id']
        return self.policy(user)

    def allowed(self, authorization):
        policy = self.authorization_policy(authorization)
        return set(policy['rooms']) | set(policy.get('aliases', []))

    def policy(self, user):
        directory=Path(os.environ['MONASTACK_MATRIX_DIR'])
        bridge=json.loads((directory/'bridge.json').read_text())
        authority=os.environ.get('MONASTACK_MATRIX_AUTHORITY_URL','http://127.0.0.1:47830')
        address=urllib.parse.urlsplit(authority)
        if address.scheme!='http' or not ipaddress.ip_address(address.hostname).is_loopback or not address.port or address.path not in ('','/') or address.username or address.query:
            raise ValueError('Gateway authority must be loopback HTTP')
        request=urllib.request.Request(authority+'/v1/chat/authorize',data=json.dumps({'user_id':user}).encode(),
            headers={'Authorization':'Bearer '+bridge['admin_token'],'Content-Type':'application/json'})
        with OPENER.open(request,timeout=10) as response:
            return json.load(response)

    def valid_jwt(self, token):
        try:
            if not isinstance(token,str) or len(token)>4096: return False
            bridge=json.loads((Path(os.environ['MONASTACK_MATRIX_DIR'])/'bridge.json').read_text())
            header,payload,signature=token.split('.')
            decode=lambda text:base64.urlsafe_b64decode(text+'='*(-len(text)%4))
            metadata = json.loads(decode(header))
            if not isinstance(metadata, dict) or metadata.get('alg')!='HS256': return False
            expected=hmac.new(bridge['jwt_secret'].encode(),(header+'.'+payload).encode(),hashlib.sha256).digest()
            if not hmac.compare_digest(expected,decode(signature)): return False
            claims=json.loads(decode(payload))
            if not isinstance(claims, dict): return False
            if claims.get('iss')!='monastack-node' or claims.get('aud')!='monastack-matrix': return False
            # Synapse permits 120 seconds of skew. The public gateway enforces
            # the contract's actual 60-second expiry without that leeway.
            if not isinstance(claims.get('exp'),(int,float)) or claims['exp']<=time.time(): return False
            if claims.get('iat',0)>time.time()+5: return False
            return bool(self.policy('@'+claims['sub']+':'+bridge['server_name'])['enabled'])
        except (ValueError,TypeError,KeyError):
            return False

    def handle_request(self):
        try:
            self.proxy()
        except urllib.error.HTTPError as error:
            self.result(401 if error.code==401 else 503,{'errcode':'M_UNKNOWN_TOKEN' if error.code==401 else 'M_UNAVAILABLE','error':'Chat authorization unavailable'})
        except (OSError, ValueError, KeyError, http.client.HTTPException):
            if not self.close_connection:
                self.result(503,{'errcode':'M_UNAVAILABLE','error':'Chat temporarily unavailable'})

    def proxy(self):
        parsed=urllib.parse.urlsplit(self.path)
        path=urllib.parse.unquote(parsed.path)
        allowed_prefix=(path.startswith('/_matrix/client/') or path.startswith('/_matrix/media/'))
        if (not allowed_prefix or parsed.scheme or parsed.netloc or '\\' in path
                or '//' in path or '/..' in path or '\x00' in path):
            self.result(404,{'errcode':'M_UNRECOGNIZED','error':'Unknown endpoint'})
            return
        if path.endswith('/createRoom') or path.endswith('/sync') and path not in ('/_matrix/client/v3/sync','/_matrix/client/r0/sync'):
            self.result(403,{'errcode':'M_FORBIDDEN','error':'Use node-owned conversations and standard sync'})
            return
        if self.headers.get('Transfer-Encoding'):
            self.result(411,{'errcode':'M_BAD_JSON','error':'Content length required'})
            return
        length=int(self.headers.get('Content-Length','0'))
        if length<0 or length>55*1024*1024:
            self.result(413,{'errcode':'M_TOO_LARGE','error':'Request too large'})
            return
        authorization=self.headers.get('Authorization')
        query=urllib.parse.parse_qs(parsed.query)
        # Bearer headers are mandatory for authenticated operations. Never let
        # query-token authentication bypass policy or put tokens in upstream logs.
        if 'access_token' in query:
            self.result(400,{'errcode':'M_INVALID_PARAM','error':'Use a bearer authorization header'})
            return
        body=self.rfile.read(length) if length else None
        if path.endswith('/login') and self.command=='POST' and body:
            try:
                login=json.loads(body)
            except ValueError:
                self.result(400,{'errcode':'M_BAD_JSON','error':'Invalid login JSON'})
                return
            if not isinstance(login, dict):
                self.result(400,{'errcode':'M_BAD_JSON','error':'Login body must be an object'})
                return
            if login.get('type')=='org.matrix.login.jwt' and not self.valid_jwt(login.get('token','')):
                self.result(403,{'errcode':'M_FORBIDDEN','error':'JWT login refused'})
                return
        rooms=self.allowed(authorization) if authorization else set()
        room_scoped = any(part.startswith(('!', '#')) for part in path.split('/'))
        if not room_access(path, rooms):
            self.result(403,{'errcode':'M_FORBIDDEN','error':'Office room access denied or unsupported room endpoint'})
            return
        if path.endswith('/events') or path.endswith('/initialSync'):
            self.result(403,{'errcode':'M_FORBIDDEN','error':'Use sync'})
            return
        if path.endswith('/search') and body:
            value=json.loads(body)
            if not isinstance(value, dict):
                self.result(400,{'errcode':'M_BAD_JSON','error':'Search body must be an object'})
                return
            category=value.get('search_categories',{}).get('room_events')
            if category is not None:
                filters=category.setdefault('filter',{})
                requested=filters.get('rooms',list(rooms))
                filters['rooms']=list({room for room in rooms if room.startswith('!')}.intersection(requested)) or ['!unauthorized:invalid']
                body=json.dumps(value).encode()
        upstream=http.client.HTTPConnection('127.0.0.1',int(os.environ.get('MONASTACK_MATRIX_ADMIN_PORT','8009')),timeout=75)
        headers={k:v for k,v in self.headers.items() if k.lower() not in HOP|{'host','content-length'}}
        if body is not None: headers['Content-Length']=str(len(body))
        upstream.request(self.command,self.path,body,headers)
        response=upstream.getresponse()
        content=response.read()
        status=response.status
        response_headers=response.getheaders()
        upstream.close()
        # Recheck after sync/search so a pending request cannot cross an epoch.
        if authorization and (path.endswith('/sync') or path.endswith('/search') or path.endswith('/notifications') or path.endswith('/joined_rooms') or path.endswith('/user_directory/search') or room_scoped):
            rooms=self.allowed(authorization)
            if not room_access(path, rooms):
                self.result(403,{'errcode':'M_FORBIDDEN','error':'Office room access denied'})
                return
            if status==200 and not room_scoped:
                value=json.loads(content)
                if path.endswith('/sync'):
                    strip_revoked_sync(value, rooms)
                if path.endswith('/user_directory/search'):
                    allowed_users = set(self.authorization_policy(authorization).get('users', []))
                    value['results'] = [u for u in value.get('results', []) if u.get('user_id') in allowed_users]
                elif path.endswith('/search'):
                    events=value.get('search_categories',{}).get('room_events',{})
                    events['results']=[r for r in events.get('results',[]) if r.get('result',{}).get('room_id') in rooms]
                    events['count']=len(events['results'])
                if path.endswith('/joined_rooms'):
                    value['joined_rooms']=[r for r in value.get('joined_rooms',[]) if r in rooms]
                if path.endswith('/notifications'):
                    value['notifications']=[n for n in value.get('notifications',[]) if n.get('room_id') in rooms]
                content=json.dumps(value).encode()
        if status==200 and path=='/_matrix/client/versions':
            value=json.loads(content)
            for feature in value.get('unstable_features',{}):
                if 'msc3575' in feature: value['unstable_features'][feature]=False
            content=json.dumps(value).encode()
        self.send_response(status)
        for key,value in response_headers:
            if key.lower() not in HOP|{'server','date','content-length'}: self.send_header(key,value)
        self.send_header('Content-Length',str(len(content)))
        self.send_header('Connection','close')
        self.end_headers()
        self.wfile.write(content)
        self.close_connection=True

    do_GET = do_POST = do_PUT = do_DELETE = do_OPTIONS = handle_request

if __name__=='__main__':
    server=ThreadingHTTPServer((os.environ.get('MONASTACK_MATRIX_BIND_HOST','0.0.0.0'),int(os.environ.get('MONASTACK_MATRIX_PORT','8008'))),ClientOnly)
    print(f'Matrix client gateway listening on {server.server_address}',flush=True)
    server.serve_forever()
