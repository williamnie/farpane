#!/usr/bin/env python3
"""Build an empty runtime root using only the ELF dependency closure; no FFmpeg."""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess
import sys

core = Path('/workspace/Build/Linux/target') / sys.argv[1] / 'liblibrustdesk.so'
root = Path('/workspace/Build/Linux') / ('load-root-' + hashlib.sha256(core.read_bytes()).hexdigest()[:12])
manifest_path = root.parent / 'logs' / (root.name + '-manifest.json')
loader = Path('/workspace/Build/Linux/bin/p0-load')
if root.exists():
    manifest = json.loads(manifest_path.read_text())
    recorded = {e['path']: e['sha256'] for e in manifest}
    actual = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in root.rglob('*') if p.is_file()}
    if actual != recorded or any(recorded['probe/'+p.name] != hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in (loader, core)):
        raise SystemExit('Refusing to reuse a changed load-root or stale binary')
    print(f'Reusing verified ELF-only runtime: {len(manifest)} files')
    sys.exit(0)
root.mkdir()
manifest = []
for path in (loader, core):
    output = subprocess.check_output(['ldd', str(path)], text=True)
    if 'not found' in output:
        raise SystemExit(output)
    for dependency in re.findall(r'(?:=>\s*)?(/[^\s()]+)', output):
        dep = Path(dependency)
        if re.match(r'lib(?:avcodec|avformat|avfilter|avutil|avdevice|swscale|swresample|postproc)\b', dep.name):
            raise SystemExit(f'System FFmpeg dependency: {dep}')
        dest = root / str(dep).lstrip('/')
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(dep, dest)
    dest = root / 'probe' / path.name
    dest.parent.mkdir(exist_ok=True)
    shutil.copyfile(path, dest)
    dest.chmod(0o755)
for path in sorted(root.rglob('*')):
    if path.is_file():
        path.chmod(0o755)
        manifest.append({'path':str(path.relative_to(root)), 'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
manifest_path.write_text(json.dumps(manifest, indent=2)+'\n')
print(f'Isolated runtime: {len(manifest)} ELF files, no FFmpeg library or executable')
