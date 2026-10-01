"""Real app replacement and failed-start rollback in an isolated macOS folder."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

archive = Path(__file__).resolve().parents[1] / 'dist/NameGuard-Desktop.zip'
helper = Path(__file__).resolve().parents[1] / 'resources/update.sh'
with tempfile.TemporaryDirectory(prefix='nameguard-update-') as temporary:
    base = Path(temporary).resolve()
    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(base / 'unpacked')], check=True)
    payload = base / 'unpacked/NameGuard-Desktop/NameGuard Desktop.app'
    for success in (True, False):
        root = base / ('success' if success else 'rollback')
        target = root / "Applications/NameGuard Desktop.app"
        state = root / 'Library/Application Support/NameGuardDesktop'
        state.mkdir(parents=True)
        target.parent.mkdir(parents=True)
        config = json.dumps({'roots': [], 'quietSeconds': 1, 'directoryQuietSeconds': 2, 'protectedApps': [], 'excludedPaths': ['/keep']})
        pause = '{"paused":true}'
        (state / 'config.json').write_text(config)
        (state / 'menu.json').write_text(pause)
        (state / 'login.json').write_text('{"enabled":false}')
        token = str(uuid.uuid4())
        workspace = state / 'updates' / token
        workspace.mkdir(parents=True)
        candidate = Path(str(target) + '.nameguard-update-' + token + '.app')
        subprocess.run(['/usr/bin/ditto', str(payload), str(target)], check=True)
        subprocess.run(['/usr/bin/ditto', str(payload), str(candidate)], check=True)
        (target / 'old-marker').write_text('old')
        (candidate / 'new-marker').write_text('new')
        if not success:
            binary = candidate / 'Contents/MacOS/nameguard'
            binary.write_text('#!/bin/sh\nexit 1\n')
            binary.chmod(0o755)
        stopped = subprocess.Popen(['/usr/bin/true'])
        stopped.wait()
        try:
            result = subprocess.run(['/bin/bash', str(helper), str(stopped.pid), str(target), str(candidate), str(workspace), token, '1.2.0', str(state), '100'], timeout=30)
            assert result.returncode == (0 if success else 1)
            assert (workspace / 'status').read_text().strip() == ('installed' if success else 'rollback')
            assert (target / ('new-marker' if success else 'old-marker')).exists()
            assert (state / 'config.json').read_text() == config
            assert (state / 'menu.json').read_text() == pause
            assert json.loads((state / 'login.json').read_text())['enabled'] is False
            if success:
                assert (workspace / 'previous.app/old-marker').exists()
                assert (workspace / 'health').read_text() == '1.2.0'
            print('PASS: real native app ' + ('replacement, health acknowledgement and relaunch' if success else 'failed-start rollback and old app relaunch') + '; folders/pause/startup preference preserved', flush=True)
        finally:
            if (workspace / 'app.pid').exists():
                pid = int((workspace / 'app.pid').read_text())
                try:
                    os.kill(pid, signal.SIGTERM)
                    time.sleep(3)
                except ProcessLookupError:
                    pass
