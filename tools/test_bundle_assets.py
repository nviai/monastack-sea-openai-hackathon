"""Verify the macOS bundle script rejects divergent map/seed copies without overwriting them."""
import os
from pathlib import Path
import subprocess
import tempfile

script = Path(__file__).resolve().parents[1] / 'app/macos/scripts/bundle_core.sh'
with tempfile.TemporaryDirectory(prefix='monastack asset test ') as directory:
    root = Path(directory)
    source = root / 'source'
    core = source / 'core'
    assets = root / 'client/app/assets'
    project = root / 'client/app/macos'
    records = source / 'data/seed/nviai'
    for path in (core / 'target/debug', assets, project, records):
        path.mkdir(parents=True, exist_ok=True)
    (root / 'client/core').symlink_to(core, target_is_directory=True)
    for name in ('map.v2.json', 'seed.v1.json'):
        (records / name).write_text('synthetic source ' + name)
        (assets / name).write_text('synthetic source ' + name)
    (core / 'target/debug/libmonastack_core.dylib').write_text('synthetic library')
    marker = root / 'cargo-called'
    fake_cargo = root / 'synthetic-cargo'
    fake_cargo.write_text('#!/bin/sh\n: > "$PROBE_MARKER"\n')
    fake_cargo.chmod(0o755)
    env = {**os.environ, 'PROJECT_DIR': str(project), 'CARGO_BIN': str(fake_cargo),
           'PROBE_MARKER': str(marker), 'TARGET_BUILD_DIR': str(root / 'build'),
           'FRAMEWORKS_FOLDER_PATH': 'Frameworks', 'CODE_SIGNING_ALLOWED': 'NO'}
    result = subprocess.run([str(script)], env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert marker.exists()
    assert (root / 'build/Frameworks/libmonastack_core.dylib').read_text() == 'synthetic library'
    marker.unlink()
    for name in ('map.v2.json', 'seed.v1.json'):
        asset = assets / name
        original = asset.read_text()
        asset.write_text('synthetic divergent asset')
        result = subprocess.run([str(script)], env=env, capture_output=True, text=True)
        assert result.returncode != 0 and name in result.stderr
        assert not marker.exists()
        assert asset.read_text() == 'synthetic divergent asset'
        assert (records / name).read_text() == original
        asset.write_text(original)
    print('Bundle asset checks: matching files accepted; divergent files rejected without overwrite')
