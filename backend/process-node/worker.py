"""Explicit one-shot prototype worker for disposable, networkless containers.

It is not configured automatically and never mounts the real workspace. A
configured command receives the approved instruction on stdin. Only a bounded
summary is reported to the loopback node. This is not yet a Codex integration.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import stat
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from container_spike import run


def validate_node(value: str) -> str:
    parsed=urllib.parse.urlsplit(value)
    try: port=parsed.port
    except ValueError: raise ValueError('invalid node port') from None
    if parsed.scheme!='http' or parsed.hostname!='127.0.0.1' or not port or not 1<=port<=65535 or parsed.username is not None or parsed.password is not None or parsed.path not in ('','/') or parsed.query or parsed.fragment:
        raise ValueError('node must be a literal loopback HTTP origin with a port')
    return f'http://127.0.0.1:{port}'


def read_token(path: Path) -> str:
    flags=os.O_RDONLY|getattr(os,'O_NOFOLLOW',0)
    fd=os.open(path,flags)
    try:
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size>512:
            raise ValueError('token file must be a private regular file')
        token=os.read(fd,513).decode('ascii').strip()
    finally:
        os.close(fd)
    if not re.fullmatch(r'[A-Za-z0-9_-]{32,256}',token):
        raise ValueError('invalid host token')
    return token


def request(base: str, token: str, method: str, path: str, body=None):
    data=None if body is None else json.dumps(body,separators=(',',':')).encode()
    req=urllib.request.Request(base+'/v1/'+path,method=method,data=data,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=2) as response:
        raw=response.read(65537)
        if len(raw)>65536: raise ValueError('node response too large')
        return json.loads(raw) if raw else None


def once(base: str, token: str, image: str, command: list[str], scratch_root: Path | None = None, codex_state_tmpfs: bool = False) -> str:
    jobs=request(base,token,'GET','host/jobs')
    if not jobs: return 'no approved job'
    job=jobs[0]['id']
    if not isinstance(job,str) or not re.fullmatch(r'[A-Za-z0-9_-]{16,80}',job): raise ValueError('invalid job id')
    lease=request(base,token,'POST','host/claim',{'job':job})
    if lease['job']!=job or not isinstance(lease['instruction'],str): raise ValueError('invalid lease')
    remaining=min(25.0,float(lease['deadline'])-time.time()-2.0)
    if remaining<=0: return 'claim expired before start'
    stop=threading.Event(); cancel=threading.Event(); deadline=time.monotonic()+remaining
    previous={}
    def signal_stop(signum,frame): cancel.set()
    for sig in (signal.SIGINT,signal.SIGTERM):
        previous[sig]=signal.signal(sig,signal_stop)
    def watch():
        while not stop.is_set():
            if time.monotonic()>=deadline:
                cancel.set();return
            try:
                control=request(base,token,'GET','host/jobs/'+urllib.parse.quote(job,safe='')+'/control')
                if control.get('active') is not True:
                    cancel.set();return
            except Exception:
                cancel.set();return
            stop.wait(.4)
    watcher=threading.Thread(target=watch,daemon=True);watcher.start()
    try:
        with tempfile.TemporaryDirectory(prefix='monastack-worker-', dir=scratch_root) as directory:
            # This is an empty disposable directory, not the workspace.
            root=Path(directory)
            result=run(image,command,root,input_data=lease['instruction'].encode(),timeout=remaining,cancel=cancel,marker=job,codex_state_tmpfs=codex_state_tmpfs)
        if cancel.is_set(): return 'claim stopped; no report submitted'
        summary=result.output[:3000].decode('utf-8',errors='replace').strip()
        if not summary: summary=f'Container ended: {result.reason}, exit {result.returncode}'
        # Replacement characters can expand a byte slice in UTF-8.
        while len(summary.encode())>3900: summary=summary[:-1]
        report={'fence':lease['fence'],'outcome':'success' if result.reason=='exited' and result.returncode==0 else 'failure','summary':summary,'op':str(uuid.uuid4())}
        path='host/jobs/'+urllib.parse.quote(job,safe='')+'/report'
        for attempt in range(2):
            if cancel.is_set(): return 'claim stopped; no report submitted'
            try:
                request(base,token,'POST',path,report)
                return 'host report recorded'
            except (OSError,urllib.error.URLError):
                if attempt: raise
        raise RuntimeError('report could not be confirmed')
    finally:
        stop.set();watcher.join(timeout=3)
        for sig,handler in previous.items(): signal.signal(sig,handler)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--node',required=True,help='literal http://127.0.0.1:PORT')
    parser.add_argument('--token-file',type=Path,required=True)
    parser.add_argument('--image',required=True,help='already-present sha256 image ID')
    parser.add_argument('--command-file',type=Path,required=True,help='JSON array of fixed command arguments')
    parser.add_argument('--scratch-root',type=Path,help='existing directory for a fresh disposable child directory')
    parser.add_argument('--codex-state-tmpfs',action='store_true',help='provide an ephemeral /.codex directory for compatible images')
    args=parser.parse_args()
    base=validate_node(args.node);token=read_token(args.token_file)
    if not re.fullmatch(r'sha256:[0-9a-f]{64}',args.image): raise ValueError('pinned image ID required')
    command=json.loads(args.command_file.read_text())
    if not isinstance(command,list) or not command or len(command)>32 or not all(isinstance(a,str) and '\x00' not in a for a in command) or not command[0].startswith('/') or sum(map(len,command))>8192:
        raise ValueError('command must be a bounded JSON string array beginning with an absolute path')
    print(once(base,token,args.image,command,args.scratch_root,args.codex_state_tmpfs))

if __name__=='__main__':
    try: main()
    except Exception as error:
        # Never print tokens, command output, or server response bodies.
        print('worker failed:',type(error).__name__,file=sys.stderr)
        raise SystemExit(1)
