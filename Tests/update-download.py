"""Serve the built product over real loopback HTTP for native download verification."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import threading

root = Path(__file__).resolve().parents[1]
server = ThreadingHTTPServer(('127.0.0.1', 0), partial(SimpleHTTPRequestHandler, directory=str(root / 'dist')))
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    subprocess.run([str(root / '.build/update-download-smoke'), str(root / 'dist/NameGuard-Desktop.zip'), f'http://127.0.0.1:{server.server_port}/NameGuard-Desktop.zip'], check=True, timeout=120)
finally:
    server.shutdown()
    server.server_close()
