"""Real APFS + FSEvents tests; modifies only disposable fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unicodedata
import unittest

BINARY = Path(__file__).resolve().parents[1] / ".build/nameguard"


class Integration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="nameguard-test-")
        self.base = Path(self.tmp.name).resolve()
        self.root = self.base / "root"
        self.root.mkdir()
        self.state = self.base / "state"
        self.state.mkdir()
        self.config = {"roots": [str(self.root)], "quietSeconds": 1,
                       "directoryQuietSeconds": 2, "excludedPaths": [], "protectedApps": []}
        self.proc = None
        self.error = open(self.base / "stderr", "w+")

    def tearDown(self):
        if self.proc:
            self.proc.terminate()
            self.proc.wait(timeout=15)
        self.error.close()
        self.tmp.cleanup()

    def start(self):
        path = self.base / "config.json"
        path.write_text(json.dumps(self.config))
        self.proc = subprocess.Popen([str(BINARY), "--watch", "--config", str(path),
                                      "--state-dir", str(self.state)], stderr=self.error)
        self.wait(lambda: (self.state / "status.json").exists())

    def wait(self, condition, timeout=20):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if condition():
                return
            if self.proc and self.proc.poll() is not None:
                self.error.seek(0)
                self.fail("watcher exited: " + self.error.read())
            time.sleep(0.2)
        self.fail("condition timed out; log=" + ((self.state / "events.jsonl").read_text()
                                               if (self.state / "events.jsonl").exists() else ""))

    def nfc(self, directory, name):
        # Python uses code point equality, unlike Swift's canonical String equality.
        return name in os.listdir(directory)

    def test_existing_new_nested_rename_content_inode_and_symlink(self):
        name = "한글.txt"
        old = self.root / unicodedata.normalize("NFD", name)
        old.write_bytes(b"unchanged\x00\xff")
        inode = old.stat().st_ino
        normal = self.root / "정상.txt"
        normal.write_bytes(b"already NFC")
        normal_stat = normal.stat()
        outside = self.base / "outside"
        outside.mkdir()
        untouched = outside / unicodedata.normalize("NFD", "외부.txt")
        untouched.touch()
        (self.root / "link").symlink_to(outside, target_is_directory=True)
        package = self.root / "Test.app"
        package.mkdir()
        (package / unicodedata.normalize("NFD", name)).touch()
        self.start()
        self.wait(lambda: self.nfc(self.root, name))
        self.assertEqual((self.root / name).read_bytes(), b"unchanged\x00\xff")
        self.assertEqual((self.root / name).stat().st_ino, inode)
        self.assertEqual(normal.stat().st_ctime_ns, normal_stat.st_ctime_ns)
        self.assertFalse(self.nfc(outside, "외부.txt"))
        self.assertFalse(self.nfc(package, name))
        # Directory with preexisting children moved into the watched hierarchy.
        incoming = self.base / unicodedata.normalize("NFD", "새폴더")
        incoming.mkdir()
        (incoming / unicodedata.normalize("NFD", "복사.txt")).write_bytes(b"copy")
        incoming.rename(self.root / incoming.name)
        self.wait(lambda: self.nfc(self.root, "새폴더"))
        self.wait(lambda: self.nfc(self.root / "새폴더", "복사.txt"))
        (self.root / name).rename(self.root / unicodedata.normalize("NFD", "변경.txt"))
        self.wait(lambda: self.nfc(self.root, "변경.txt"))
        created = self.root / "새폴더" / unicodedata.normalize("NFD", "유입.txt")
        created.write_bytes(b"new")
        self.wait(lambda: self.nfc(self.root / "새폴더", "유입.txt"))

    def test_open_file_defers_then_retries_without_another_event(self):
        name = "사용중.txt"
        folder = self.root / unicodedata.normalize("NFD", "작업폴더")
        folder.mkdir()
        path = folder / unicodedata.normalize("NFD", name)
        with path.open("wb") as held:
            held.write(b"held")
            held.flush()
            self.start()
            time.sleep(6)
            self.assertFalse(self.nfc(folder, name))
            self.assertFalse(self.nfc(self.root, "작업폴더"))
        self.wait(lambda: self.nfc(folder, name), timeout=40)
        self.wait(lambda: self.nfc(self.root, "작업폴더"))

    def test_excluded_path_and_duplicate_roots(self):
        excluded = self.root / "excluded"
        excluded.mkdir()
        (excluded / unicodedata.normalize("NFD", "제외.txt")).touch()
        alias = self.base / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        self.config["roots"].append(str(alias))
        self.config["excludedPaths"] = [str(excluded)]
        self.start()
        time.sleep(4)
        self.assertFalse(self.nfc(excluded, "제외.txt"))
        state = json.loads((self.state / "status.json").read_text())
        self.assertEqual(len(state["roots"]), 1)

    def test_sync_loop_cooldown(self):
        self.start()
        name = "반복.txt"
        decomposed = unicodedata.normalize("NFD", name)
        (self.root / decomposed).touch()
        for _ in range(3):
            self.wait(lambda: self.nfc(self.root, name))
            (self.root / name).rename(self.root / decomposed)
        self.wait(lambda: '"event":"cooldown"' in (self.state / "events.jsonl").read_text())
        self.assertFalse(self.nfc(self.root, name))

    def test_running_protected_app_pauses_and_restart_recovers(self):
        self.config["protectedApps"] = ["Finder"]
        path = self.root / unicodedata.normalize("NFD", "보류.txt")
        path.touch()
        self.start()
        self.wait(lambda: "Finder" in json.loads((self.state / "status.json").read_text())["paused"])
        self.assertFalse(self.nfc(self.root, "보류.txt"))
        self.proc.terminate()
        self.proc.wait(timeout=15)
        (self.state / "status.json").unlink()
        self.config["protectedApps"] = []
        self.start()
        self.wait(lambda: self.nfc(self.root, "보류.txt"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
