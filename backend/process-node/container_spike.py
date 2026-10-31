"""Synthetic Docker isolation experiment, not an enrolled agent host.

It runs only explicitly supplied commands in an already-present pinned image.
It is not connected to the office node and does not run Codex or workspace data.
"""
from __future__ import annotations

import os
import re
import selectors
import stat
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

MAX_INPUT = 16384
MAX_OUTPUT = 65536

@dataclass(frozen=True)
class Result:
    reason: str
    returncode: int
    output: bytes


def run(image: str, command: Sequence[str], directory: Path, *, input_data: bytes = b'', timeout: float = 10, cancel: threading.Event | None = None, marker: str | None = None, codex_state_tmpfs: bool = False) -> Result:
    """Start one networkless, resource-limited container with one writable mount.

    The caller owns the disposable mount and must not mount a live workspace.
    Container ownership is a random name generated for this invocation; cleanup
    targets only that name. This is an experiment, not a security certification.
    """
    root = Path(directory).resolve(strict=True)
    if not root.is_dir() or ',' in str(root) or '\n' in str(root) or not re.fullmatch(r'sha256:[0-9a-f]{64}', image):
        raise ValueError('existing directory and pinned image ID required')
    if os.getuid()==0:
        raise ValueError('the experiment requires a non-root caller')
    if os.environ.get('DOCKER_HOST') or os.environ.get('DOCKER_CONTEXT'):
        raise ValueError('Docker host and context overrides are not supported')
    endpoint = subprocess.check_output(['docker','context','inspect','--format','{{.Endpoints.docker.Host}}'],text=True,timeout=5).strip()
    if not endpoint.startswith('unix:///') or not stat.S_ISSOCK(os.stat(endpoint.removeprefix('unix://')).st_mode):
        raise ValueError('a local Docker Unix socket is required')
    if not command or not all(isinstance(x, str) and '\x00' not in x for x in command):
        raise ValueError('invalid command')
    if not 0 < timeout <= 30 or len(input_data) > MAX_INPUT:
        raise ValueError('invalid limits')
    if marker is not None and not re.fullmatch(r'[A-Za-z0-9_-]{16,80}', marker):
        raise ValueError('invalid job marker')
    if cancel is not None and cancel.is_set():
        return Result('cancelled', -1, b'')
    name = 'monastack-spike-' + uuid.uuid4().hex
    create = ['docker','--host',endpoint,'create','--name',name,'--pull','never','--network','none',
              '--read-only','--cap-drop','ALL','--security-opt','no-new-privileges',
              '--log-driver','none',
              '--pids-limit','64','--memory','256m','--cpus','0.5',
              '--user',f'{os.getuid()}:{os.getgid()}','--workdir','/work',
              '--mount',f'type=bind,source={root},target=/work',
              '--tmpfs','/tmp:rw,noexec,nosuid,size=8m','--interactive']
    if marker is not None: create.extend(['--label',f'com.monastack.job={marker}'])
    if codex_state_tmpfs:
        # Some images resolve the non-root user's home to /. Keep state ephemeral.
        create.extend(['--tmpfs',f'/.codex:rw,noexec,nosuid,size=16m,uid={os.getuid()},gid={os.getgid()},mode=0700'])
    create.extend([image,*command])
    proc = None
    created = False
    watchdog = None
    watchdog_write = None
    try:
        made=subprocess.run(create,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20,check=False)
        if made.returncode != 0:
            raise RuntimeError('container creation failed: '+made.stderr.decode(errors='replace')[:500])
        created = True
        if cancel is not None and cancel.is_set():
            return Result('cancelled', -1, b'')
        watchdog_read, watchdog_write = os.pipe()
        try:
            watchdog = subprocess.Popen([sys.executable, str(Path(__file__).with_name('container_watchdog.py')), name, str(timeout + 1), str(watchdog_read), endpoint], pass_fds=(watchdog_read,), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        finally:
            os.close(watchdog_read)
        proc=subprocess.Popen(['docker','--host',endpoint,'start','--attach','--interactive',name],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        assert proc.stdin is not None and proc.stdout is not None
        selector=selectors.DefaultSelector()
        selector.register(proc.stdout,selectors.EVENT_READ)
        os.set_blocking(proc.stdin.fileno(),False)
        sent=0
        if input_data: selector.register(proc.stdin,selectors.EVENT_WRITE)
        else: proc.stdin.close()
        output=bytearray(); deadline=time.monotonic()+timeout; reason='exited'
        try:
            while True:
                if cancel is not None and cancel.is_set(): reason='cancelled'; break
                if time.monotonic() >= deadline: reason='timeout'; break
                for key,_ in selector.select(min(.05,max(0,deadline-time.monotonic()))):
                    if key.fileobj is proc.stdin:
                        try: sent+=os.write(key.fd,input_data[sent:sent+4096])
                        except BrokenPipeError: sent=len(input_data)
                        if sent == len(input_data): selector.unregister(proc.stdin); proc.stdin.close()
                        continue
                    chunk=os.read(key.fd,8192)
                    if not chunk: selector.unregister(key.fileobj)
                    else:
                        output.extend(chunk)
                        if len(output)>MAX_OUTPUT: del output[MAX_OUTPUT:]; reason='output_limit'; break
                if reason!='exited': break
                if proc.poll() is not None and not selector.get_map(): break
            if reason=='exited': proc.wait(timeout=3)
            return Result(reason,proc.returncode if proc.returncode is not None else -1,bytes(output))
        finally:
            selector.close()
            if not proc.stdin.closed: proc.stdin.close()
            proc.stdout.close()
    finally:
        # Force-removal is limited to the random name allocated above.
        removed = subprocess.run(['docker','--host',endpoint,'rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10,check=False) if created else None
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try: proc.wait(timeout=3)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=3)
        if watchdog_write is not None:
            if removed is not None and removed.returncode == 0:
                try: os.write(watchdog_write, b'q')
                except BrokenPipeError: pass
            os.close(watchdog_write)
        if watchdog is not None:
            try: watchdog.wait(timeout=3)
            except subprocess.TimeoutExpired: watchdog.terminate(); watchdog.wait(timeout=3)
        if created and removed is not None and removed.returncode != 0:
            raise RuntimeError('could not verify removal of the test container: '+name)
