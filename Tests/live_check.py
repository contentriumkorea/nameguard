"""Check the installed daemon using disposable files in real watched roots."""
import json
import os
from pathlib import Path
import tempfile
import time
import unicodedata

home = Path.home()
roots = [home / "Desktop", home / "Library/CloudStorage/Dropbox"]
fixtures = []
try:
    for root in roots:
        directory = Path(tempfile.mkdtemp(prefix="NameGuard-check-", dir=root))
        folder = directory / unicodedata.normalize("NFD", "검증폴더")
        folder.mkdir()
        file = folder / unicodedata.normalize("NFD", "한글검증.txt")
        file.write_bytes(b"NameGuard NFC verification\n")
        fixtures.append((directory, folder, file.stat().st_ino))
    end = time.monotonic() + 120
    while time.monotonic() < end:
        if all("검증폴더" in os.listdir(d) and "한글검증.txt" in os.listdir(d / "검증폴더")
               for d, _, _ in fixtures):
            break
        time.sleep(1)
    for directory, _, inode in fixtures:
        assert "검증폴더" in os.listdir(directory), str(directory) + ": folder not NFC"
        folder = directory / "검증폴더"
        assert "한글검증.txt" in os.listdir(folder), str(directory) + ": file not NFC"
        file = folder / "한글검증.txt"
        assert file.stat().st_ino == inode
        assert file.read_bytes() == b"NameGuard NFC verification\n"
        print("PASS installed daemon:", directory.parent, "file+folder NFC; content+inode preserved", flush=True)
finally:
    # Remove only our two known items; never recursively remove user content.
    for directory, folder, _ in fixtures:
        file = folder / "한글검증.txt"
        if file.exists():
            file.unlink()
        if folder.exists():
            folder.rmdir()
        directory.rmdir()
