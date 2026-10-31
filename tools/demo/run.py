"""Record the opt-in Flutter demo target. Password comes from environment only."""
import os, sys, time, signal, subprocess
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import local_office as office
root = Path(__file__).resolve().parents[2]
def main():
    if not os.environ.get('MONASTACK_DEMO_PASSWORD'):
        raise SystemExit('Set MONASTACK_DEMO_PASSWORD before running.')
    folder = root/'runtime/demo'/time.strftime('%Y%m%d-%H%M%S')
    folder.mkdir(parents=True)
    control = Path.home()/'Library/Containers/com.example.monastack/Data/tmp'/folder.name
    control.mkdir(parents=True, exist_ok=True)
    executable = root/'runtime/demo/record'
    subprocess.run(['swiftc','-parse-as-library',str(root/'tools/demo/record.swift'),'-o',str(executable)],check=True)
    old = office.running('app')
    if old:
        os.kill(old,signal.SIGTERM)
        for _ in range(50):
            if not office.running('app'): break
            time.sleep(.1)
        if office.running('app'): raise RuntimeError('App did not stop')
    env = {**office.environment('client'), 'MONASTACK_CREDENTIAL_STORE':'memory',
           'MONASTACK_SIGN_IN':'password', 'MONASTACK_DEMO_DIR':str(control)}
    recorder = None
    with (folder/'app.log').open('w') as log, (folder/'recorder.log').open('w') as rec_log:
        app = subprocess.Popen([str(office.APP)],env=env,stdout=log,stderr=subprocess.STDOUT)
        office.pid_file('app').write_text(str(app.pid))
        try:
            deadline = time.monotonic()+75
            while not (control/'ready').exists():
                if app.poll() is not None or time.monotonic()>deadline or 'Some tests failed' in (folder/'app.log').read_text():
                    raise RuntimeError(f'Demo login did not appear. See {folder}/app.log')
                time.sleep(.2)
            recorder = subprocess.Popen([str(executable),str(folder/'demo-raw.mp4'),'280',str(app.pid),str(folder/'stop-recording')],stdout=rec_log,stderr=subprocess.STDOUT)
            deadline = time.monotonic()+25
            while 'RECORDING_STARTED' not in (folder/'recorder.log').read_text():
                if recorder.poll() is not None or time.monotonic()>deadline:
                    raise RuntimeError(f'Recorder did not start. See {folder}/recorder.log')
                time.sleep(.2)
            (control/'go').touch()
            print(f'DEMO_RECORDING {folder}',flush=True)
            deadline = time.monotonic()+270
            while not (control/'done').exists():
                if app.poll() is not None or time.monotonic()>deadline or 'Some tests failed' in (folder/'app.log').read_text() or 'Demo timed out:' in (folder/'app.log').read_text():
                    raise RuntimeError(f'Demo did not complete. See {folder}/app.log')
                time.sleep(.5)
            time.sleep(3)
            (folder/'stop-recording').touch()
            recorder.wait(timeout=20)
            if recorder.returncode: raise RuntimeError('Recorder failed')
            (folder/'chapters.jsonl').write_text((control/'chapters.jsonl').read_text())
            print(f'DEMO_COMPLETE {folder}/demo-raw.mp4',flush=True)
        finally:
            (folder/'stop-recording').touch()
            if recorder and recorder.poll() is None:
                try: recorder.wait(timeout=15)
                except subprocess.TimeoutExpired: recorder.terminate()
            if app.poll() is None:
                app.terminate()
                app.wait(timeout=10)
if __name__=='__main__': main()
