"""Bounded loopback-only TCP relay into one fixed endpoint on an internal Docker network.

This is test infrastructure, not an authenticated or production media gateway.
The Docker container must already exist and is supplied by the caller.
"""
import os
import signal
import socket
import subprocess
import threading

_RELAY = r'''import os,select,socket,sys
sock=socket.create_connection((sys.argv[1],int(sys.argv[2])),timeout=5)
sock.settimeout(None)
input_open=True
while True:
 readers=[sock]+([sys.stdin.buffer] if input_open else [])
 ready,_,_=select.select(readers,[],[])
 if sock in ready:
  data=sock.recv(65536)
  if not data: break
  view=memoryview(data)
  while view:
   written=os.write(1,view)
   view=view[written:]
 if input_open and sys.stdin.buffer in ready:
  data=os.read(0,65536)
  if not data:
   input_open=False
   sock.shutdown(socket.SHUT_WR)
  else:
   sock.sendall(data)
sock.close()
'''

class LoopbackRelay:
    def __init__(self, container, destination, port):
        self.container = container
        self.destination = destination
        self.port = port
        self.stopped = threading.Event()
        self.lock = threading.Lock()
        self.children = set()
        self.sockets = set()
        self.limit = threading.BoundedSemaphore(32)
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(('127.0.0.1', port))
        self.listener.listen(16)
        self.listener.settimeout(.2)
        self.thread = threading.Thread(target=self._accept, daemon=True)
        self.thread.start()

    def _accept(self):
        while not self.stopped.is_set():
            try:
                conn, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            if not self.limit.acquire(blocking=False):
                conn.close()
                continue
            with self.lock:
                self.sockets.add(conn)
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn):
        child = None
        try:
            child = subprocess.Popen(
                ['docker', 'exec', '-i', self.container, 'python', '-u', '-c', _RELAY,
                 self.destination, str(self.port)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            with self.lock:
                self.children.add(child)
            def upstream():
                try:
                    while not self.stopped.is_set():
                        data = conn.recv(65536)
                        if not data:
                            break
                        child.stdin.write(data)
                        child.stdin.flush()
                except (OSError, ValueError):
                    pass
                finally:
                    try:
                        child.stdin.close()
                    except (OSError, ValueError):
                        pass
            thread = threading.Thread(target=upstream, daemon=True)
            thread.start()
            while not self.stopped.is_set():
                data = os.read(child.stdout.fileno(), 65536)
                if not data:
                    break
                conn.sendall(data)
        except (OSError, ValueError):
            pass
        finally:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            conn.close()
            if child is not None:
                if child.poll() is None:
                    try:
                        os.killpg(child.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
                with self.lock:
                    self.children.discard(child)
            with self.lock:
                self.sockets.discard(conn)
            self.limit.release()

    def close(self):
        self.stopped.set()
        self.listener.close()
        with self.lock:
            sockets = list(self.sockets)
            children = list(self.children)
        for conn in sockets:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            conn.close()
        for child in children:
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        self.thread.join(timeout=2)
