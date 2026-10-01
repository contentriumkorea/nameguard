"""Unpack and stage the shareable installer without registering a real agent."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import unicodedata

archive = Path(__file__).resolve().parents[1] / "dist/NameGuard-Desktop.zip"
with tempfile.TemporaryDirectory(prefix="nameguard-distribution-") as temporary:
    base = Path(temporary).resolve()
    subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(base / "unpacked")], check=True)
    package = base / "unpacked/NameGuard-Desktop"
    installer = package / "설치.command"
    assert os.access(installer, os.X_OK), "Double-click installer must retain executable permission"
    recipient = base / "받는 사람's 계정"
    desktop = recipient / "Desktop"
    desktop.mkdir(parents=True)
    subprocess.run(["/bin/bash", str(installer), "--stage", str(recipient)], check=True)
    state = recipient / "Library/Application Support/NameGuardDesktop"
    config_path = state / "config.json"
    config = json.loads(config_path.read_text())
    assert config["roots"] == [str(desktop)]
    agent = recipient / "Library/LaunchAgents/local.nameguard.desktop.agent.plist"
    with agent.open("rb") as handle:
        launch = plistlib.load(handle)
    app = recipient / "Applications/NameGuard Desktop.app"
    binary = app / "Contents/MacOS/nameguard"
    assert launch["ProgramArguments"] == [str(binary), "--menu", "--state-dir", str(state)]
    assert launch["KeepAlive"] and launch["RunAtLoad"]
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True)
    assert set(architectures.split()) == {"arm64", "x86_64"}
    roots = subprocess.check_output([str(binary), "--roots", "--state-dir", str(state)], text=True)
    assert roots.strip() == str(desktop)
    direct_roots = subprocess.check_output([str(binary), "--roots"], text=True)
    assert direct_roots.strip() == str(desktop), "Opening the installed app directly must use the installer's settings"
    custom = recipient / "My folders"
    custom.mkdir()
    config["roots"] = [str(custom)]
    config["quietSeconds"] = 17
    config_path.write_text(json.dumps(config))
    subprocess.run(["/bin/bash", str(installer), "--stage", str(recipient)], check=True)
    saved = json.loads(config_path.read_text())
    assert saved == config, "Reinstall must preserve chosen folders and settings"
    config["roots"] = [str(desktop)]
    print("PASS: universal package, staged installer, login menu, custom settings preserved on reinstall", flush=True)

    # Restrict the smoke test to the staged fake Desktop, independent of user apps.
    config.update(quietSeconds=1, directoryQuietSeconds=2, protectedApps=[])
    config_path.write_text(json.dumps(config))
    original = desktop / unicodedata.normalize("NFD", "배포검증.txt")
    original.write_bytes(b"contents untouched")
    inode = original.stat().st_ino
    daemon = subprocess.Popen([str(binary), "--watch", "--state-dir", str(state)])
    try:
        deadline = time.monotonic() + 20
        while "배포검증.txt" not in os.listdir(desktop) and time.monotonic() < deadline:
            assert daemon.poll() is None, "Packaged daemon exited"
            time.sleep(0.2)
        assert "배포검증.txt" in os.listdir(desktop)
        assert (desktop / "배포검증.txt").read_bytes() == b"contents untouched"
        assert (desktop / "배포검증.txt").stat().st_ino == inode
        incoming = desktop / unicodedata.normalize("NFD", "새파일.txt")
        incoming.write_bytes(b"event test")
        deadline = time.monotonic() + 20
        while "새파일.txt" not in os.listdir(desktop) and time.monotonic() < deadline:
            assert daemon.poll() is None
            time.sleep(0.2)
        assert "새파일.txt" in os.listdir(desktop), "FSEvents must work in distributed binary"
        print("PASS: packaged arm64 daemon, initial normalization and new file event, preserved bytes and inode", flush=True)
    finally:
        daemon.terminate()
        daemon.wait(timeout=15)

    # Upgrade a legacy installation without resetting its Desktop + Dropbox discovery.
    legacy = base / "legacy"
    existing = legacy / "Library/LaunchAgents/local.nameguard.agent.plist"
    existing.parent.mkdir(parents=True)
    existing.touch()
    old_state = legacy / "Library/Application Support/NameGuard"
    old_state.mkdir(parents=True)
    old_config = {"quietSeconds": 10, "directoryQuietSeconds": 30, "excludedPaths": ["/keep"], "protectedApps": []}
    (old_state / "config.json").write_text(json.dumps(old_config))
    subprocess.run(["/bin/bash", str(installer), "--stage", str(legacy)], check=True)
    assert json.loads((old_state / "config.json").read_text()) == old_config
    assert not (legacy / "Library/LaunchAgents/local.nameguard.desktop.agent.plist").exists()
    with existing.open("rb") as handle:
        upgraded = plistlib.load(handle)
    assert upgraded["ProgramArguments"][1] == "--menu"
    assert upgraded["ProgramArguments"][-1] == str(old_state)
    print("PASS: legacy in-place upgrade preserves discovery and exclusions; no user environment modified", flush=True)
