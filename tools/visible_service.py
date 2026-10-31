"""Launch foreground Zellij services, or detached services with private log files.

Environment values travel in a one-use 0600 file, never command arguments or
pane titles. The launcher consumes it before replacing itself with the service.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def write_private(path, value):
    # Secure at creation, even when the caller's umask is permissive. Truncate
    # only after fchmod so an existing overly permissive file is repaired first.
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.truncate(0)
        stream.write(value)


def zellij_tab(session, name, command, cwd=ROOT):
    """Return False only when Zellij is absent. Never revive exited sessions."""
    if not shutil.which('zellij'):
        return False
    cwd = Path(cwd).resolve(strict=True)
    result = subprocess.run(['zellij', 'list-sessions', '--short', '--no-formatting'],
                            capture_output=True, text=True)
    # Zellij returns 1 for an empty session inventory.
    if result.returncode and result.stdout.strip():
        raise RuntimeError('Cannot inspect Zellij sessions')
    sessions = result.stdout.splitlines()
    if any(line.startswith(session + ' ') for line in sessions):
        raise RuntimeError(f'Zellij session {session} has exited; choose a fresh session name')
    if session not in sessions:
        subprocess.run(['zellij', 'attach', '--create-background', session], check=True)
    panes = json.loads(subprocess.run(
        ['zellij', '--session', session, 'action', 'list-panes', '--all', '--json'],
        capture_output=True, text=True, check=True).stdout)
    # 0.45.1 on this host renders --no-focus command tabs empty. Keep the bundled
    # bars and visible named command panes in Services without changing focus.
    for pane in panes:
        if pane.get('is_plugin') or pane.get('title') != name:
            continue
        if not pane.get('exited'):
            return True
        subprocess.run(['zellij', '--session', session, 'action', 'new-pane', '--no-focus',
                        '--in-place', '--close-replaced-pane', '--pane-id', 'terminal_' + str(pane['id']),
                        '--name', name, '--cwd', str(cwd), '--', *map(str, command)], check=True)
        return True
    tab_id = next((p['tab_id'] for p in panes if p.get('plugin_url') == 'zellij:tab-bar'),
                  next(p['tab_id'] for p in panes if not p.get('is_plugin')))
    subprocess.run(['zellij', '--session', session, 'action', 'rename-tab-by-id', str(tab_id), 'Services'], check=True)
    subprocess.run(['zellij', '--session', session, 'action', 'new-pane', '--no-focus',
                    '--tab-id', str(tab_id), '--name', name, '--cwd', str(cwd), '--', *map(str, command)], check=True)
    return True


def launch_service(session, name, command, env, pidfile, cwd=ROOT):
    cwd = Path(cwd).resolve(strict=True)
    pidfile = Path(pidfile)
    pidfile.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # mkstemp creates mode 0600 atomically. Files are unique across restarts.
    descriptor, filename = tempfile.mkstemp(prefix=name + '-', suffix='.env.json', dir=pidfile.parent)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(dict(env), stream)
    launcher = [sys.executable, str(Path(__file__).resolve()), str(pidfile), filename, *map(str, command)]
    try:
        if zellij_tab(session, name, launcher, cwd):
            return
        logs = pidfile.parent.parent / 'logs'
        logs.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (logs / (pidfile.stem + '.log')).open('ab') as output:
            subprocess.Popen(launcher, env=env, cwd=cwd, stdin=subprocess.DEVNULL,
                             stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    except BaseException:
        Path(filename).unlink(missing_ok=True)
        raise


if __name__ == '__main__':
    path = Path(sys.argv[1])
    environment_file = Path(sys.argv[2])
    environment = json.loads(environment_file.read_text())
    environment_file.unlink()
    write_private(path, str(os.getpid()) + '\n')
    os.execvpe(sys.argv[3], sys.argv[3:], environment)
