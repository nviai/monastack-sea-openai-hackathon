"""Build a disposable macOS Flutter app against the cached LiveKit SDK.

The generated app contains no workspace records, credentials, microphone use
or media connections. Pub resolution is offline; CocoaPods may download public
SDK binaries if they are not cached. The temporary project is removed on exit.
"""
import os
from pathlib import Path
import signal
import subprocess
import tempfile

env = {**os.environ, 'COCOAPODS_DISABLE_STATS': 'true', 'FLUTTER_SUPPRESS_ANALYTICS': 'true'}

def interrupted(_signum, _frame):
    raise KeyboardInterrupt

signal.signal(signal.SIGTERM, interrupted)

def run(command, cwd=None, timeout=180):
    process = subprocess.Popen(command, cwd=cwd, env=env, start_new_session=True)
    try:
        code = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)
        raise RuntimeError('SDK build probe timed out') from None
    except BaseException:
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=5)
        raise
    if code:
        raise RuntimeError(f'SDK build probe failed at {command[1]} (exit {code})')

with tempfile.TemporaryDirectory(prefix='monastack-media-sdk-') as directory:
    project = Path(directory) / 'app'
    run(['flutter', 'create', '--no-pub', '--platforms=macos', '--project-name', 'monastack_media_probe', str(project)])
    spec = project / 'pubspec.yaml'
    original = spec.read_text()
    marker = '\ndependencies:\n'
    if original.count(marker) != 1:
        raise RuntimeError('unexpected generated Flutter project')
    spec.write_text(original.replace(marker, marker + '  livekit_client: 2.13.1\n', 1))
    (project / 'lib/main.dart').write_text('''import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as livekit;
void main() => runApp(MaterialApp(home: Text(livekit.Room().runtimeType.toString())));
''')
    run(['flutter', 'pub', 'get', '--offline'], cwd=project)
    run(['flutter', 'build', 'macos', '--debug', '--no-pub'], cwd=project, timeout=240)
    print('Disposable Flutter/macOS app built with LiveKit SDK; no media was connected')
