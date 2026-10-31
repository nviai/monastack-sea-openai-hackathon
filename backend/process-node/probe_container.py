"""Run a local synthetic probe of the Docker isolation experiment."""
import subprocess
import json
import os
import secrets
import tempfile
import threading
import time
from pathlib import Path

from container_spike import MAX_OUTPUT, run

image=subprocess.check_output(['docker','image','inspect','alpine:3.23','--format','{{.Id}}'],text=True).strip()
with tempfile.TemporaryDirectory(prefix='monastack-container-test-') as base:
    parent=Path(base)
    work=parent/'work'; work.mkdir(mode=0o700)
    secret=parent/'synthetic-secret'; secret.write_text('private synthetic marker')
    result=run(image,['/bin/sh','-c','printf local > /work/result; cat /work/result'],work)
    assert result.reason=='exited' and result.returncode==0 and result.output==b'local', result
    result=run(image,['/bin/sh','-c','exit 7'],work)
    assert result.reason=='exited' and result.returncode==7, result
    result=run(image,['/bin/sh','-c','cat /synthetic-secret >/dev/null'],work)
    assert result.reason=='exited' and result.returncode!=0, result
    result=run(image,['/bin/sh','-c','printf bad > /outside'],work)
    assert result.reason=='exited' and result.returncode!=0, result
    result=run(image,['/bin/sh','-c','ip route show'],work)
    assert result.reason=='exited' and result.returncode==0 and result.output.strip()==b'', result
    marker=secrets.token_hex(16);event=threading.Event();holder=[]
    thread=threading.Thread(target=lambda:holder.append(run(image,['/bin/sh','-c','sleep 10'],work,cancel=event,marker=marker)))
    thread.start()
    try:
        ids=[]
        for _ in range(100):
            ids=subprocess.check_output(['docker','ps','--quiet','--filter','label=com.monastack.job='+marker],text=True).split()
            if ids: break
            time.sleep(.05)
        assert len(ids)==1, 'test container did not start'
        info=json.loads(subprocess.check_output(['docker','inspect',ids[0]],text=True))[0]
        assert info['HostConfig']['NetworkMode']=='none'
        assert info['HostConfig']['ReadonlyRootfs'] is True
        assert info['HostConfig']['LogConfig']['Type']=='none'
        assert info['Config']['User']==f'{os.getuid()}:{os.getgid()}'
    finally:
        event.set();thread.join(timeout=15)
    assert not thread.is_alive() and holder and holder[0].reason=='cancelled'
    start=time.monotonic()
    result=run(image,['/bin/sh','-c','sleep 5'],work,timeout=.3)
    assert result.reason=='timeout' and time.monotonic()-start<10, result
    result=run(image,['/usr/bin/yes'],work,timeout=5)
    assert result.reason=='output_limit' and len(result.output)==MAX_OUTPUT, result.reason
    event=threading.Event(); timer=threading.Timer(.5,event.set); timer.start()
    try:
        result=run(image,['/bin/sh','-c','sleep 5'],work,cancel=event)
        assert result.reason=='cancelled', result
    finally:
        timer.cancel()
    assert secret.read_text()=='private synthetic marker'
    print('Container spike: isolated mount, read-only root, network namespace, timeout, output cap, cancellation and cleanup passed')
