"""Remove one randomly named test container if its parent dies or deadline passes."""
import os
import re
import select
import subprocess
import sys
import time

name, seconds, descriptor, endpoint = sys.argv[1:]
if not re.fullmatch(r'monastack-spike-[0-9a-f]{32}', name) or not endpoint.startswith('unix:///'):
    raise SystemExit(2)
fd=int(descriptor)
deadline=time.monotonic()+float(seconds)
while True:
    remaining=deadline-time.monotonic()
    if remaining<=0:
        break
    ready,_,_=select.select([fd],[],[],min(remaining,.5))
    if ready:
        message=os.read(fd,1)
        if message==b'q':
            raise SystemExit(0)
        if not message:
            break
try:
    subprocess.run(['docker','--host',endpoint,'rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10,check=False)
except (OSError,subprocess.TimeoutExpired):
    pass
