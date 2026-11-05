"""Include dependency attribution/license files in the installed package."""
import json
from pathlib import Path
import subprocess
import sys

metadata = json.loads(subprocess.check_output(['cargo', 'metadata', '--locked', '--format-version', '1']))
pieces = ['NameGuard third-party dependency notices\n']
for package in sorted(metadata['packages'], key=lambda p: p['name']):
    if not package['source']:
        continue
    root = Path(package['manifest_path']).parent
    pieces.append(f"\n{'=' * 70}\n{package['name']} {package['version']}\nLicense: {package.get('license') or 'See below'}\n{package.get('repository') or ''}\n")
    files = [p for p in root.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE'))]
    if package.get('license_file'):
        files.append(root / package['license_file'])
    for path in sorted(set(files)):
        pieces.append(f'\n--- {path.name} ---\n' + path.read_text(errors='replace'))
Path(sys.argv[1]).write_text('\n'.join(pieces), encoding='utf-8')
