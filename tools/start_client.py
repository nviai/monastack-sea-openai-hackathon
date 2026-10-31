"""Launch a macOS office app against the shared LAN server; no client node needed."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT/'runtime'
APP = ROOT/'app/build/macos/Build/Products/Debug/monastack.app'
PID_FILE = RUNTIME/'pids/lan-client.pid'

def address(value):
    try:
        ip = ipaddress.IPv4Address(value)
    except ipaddress.AddressValueError:
        raise argparse.ArgumentTypeError('Use a literal private LAN IPv4 address.')
    if not any(ip in ipaddress.IPv4Network(network) for network in ['127.0.0.0/8','10.0.0.0/8','172.16.0.0/12','192.168.0.0/16']):
        raise argparse.ArgumentTypeError('Use a loopback or private LAN address.')
    return str(ip)

def running(executable):
    if not PID_FILE.exists(): return None
    pid = int(PID_FILE.read_text())
    command = subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True).stdout
    return pid if str(executable) in command else None

def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    server_config = RUNTIME/'server-address.json'
    saved_host = json.loads(server_config.read_text()).get('host') if server_config.exists() else None
    parser.add_argument('--host',type=address,default=os.environ.get('MONASTACK_SERVER_HOST') or saved_host or '192.168.224.217')
    parser.add_argument('--port',type=int,default=47830)
    parser.add_argument('--skip-build',action='store_true',help='use the existing app build')
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--check',action='store_true',help='check API connectivity without opening the app')
    group.add_argument('--stop',action='store_true',help='stop the LAN client started by this script')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535: parser.error('Port must be 1-65535.')
    executable = APP/'Contents/MacOS/monastack'
    if args.stop:
        pid = running(executable)
        if pid: os.kill(pid,signal.SIGTERM)
        PID_FILE.unlink(missing_ok=True)
        print('LAN client stopped; server was left running.')
        return
    url = f'http://{args.host}:{args.port}'
    # A LAN connection should not send workspace requests to a system proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(url+'/v1/workspace',timeout=5) as response:
            info = json.load(response)
    except (OSError,ValueError):
        raise SystemExit(f'Cannot reach {url}. Check server, network and firewall.')
    if not info.get('initialized'):
        raise SystemExit('The server has not set up its workspace yet.')
    print(f'Server ready: {url} — {info.get("workspace",{}).get("name", "office")}',flush=True)
    if args.check: return
    if sys.platform != 'darwin': raise SystemExit('This script currently launches the macOS client.')
    if not args.skip_build:
        subprocess.run(['flutter','build','macos','--debug'],cwd=ROOT/'app',check=True)
    if not executable.is_file(): raise SystemExit('App build missing. Run without --skip-build first.')
    if running(executable): raise SystemExit('A LAN client is already running. Use --stop before relaunching.')
    for folder in ['logs','pids']: (RUNTIME/folder).mkdir(parents=True,exist_ok=True,mode=0o700)
    log = RUNTIME/'logs'/f'client-{args.host}-{args.port}.log'
    env = {**os.environ,'MONASTACK_NODE_HOST':args.host,'MONASTACK_NODE_PORT':str(args.port)}
    with log.open('ab') as output:
        process = subprocess.Popen([str(executable)],cwd=ROOT,env=env,stdin=subprocess.DEVNULL,
            stdout=output,stderr=output,start_new_session=True)
    PID_FILE.write_text(str(process.pid)+'\n')
    print(f'Client started (PID {process.pid}), connected to {url}. Log: {log.relative_to(ROOT)}')
    print('Sign in with your seeded username and password. No OpenAI key or Docker is needed on this client.')

if __name__ == '__main__':
    main()
