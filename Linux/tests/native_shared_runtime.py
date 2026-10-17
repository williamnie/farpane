"""PSS diagnostic: share only byte-identical, read-only system file pages."""
import hashlib
import json
from pathlib import Path
import subprocess

# These are the dominant mapped files observed in the pinned hermes test image.
# This is a measurement mode, never an application/runtime installation path.
FILES = [
    '/usr/lib/x86_64-linux-gnu/libLLVM.so.21.1',
    '/usr/lib/x86_64-linux-gnu/libgallium-26.0.8-1ubuntu0.3.so',
    '/usr/lib/x86_64-linux-gnu/libgtk-4.so.1.2200.4',
    '/usr/lib/x86_64-linux-gnu/libadwaita-1.so.0',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc',
]


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def host_files():
    values = {}
    for name in FILES:
        path = Path(name)
        if not path.is_file() or path.is_symlink():
            raise ValueError('Expected a regular system file: ' + name)
        info = path.stat()
        values[name] = {'sha256': digest(path), 'bytes': info.st_size,
                        'device': info.st_dev, 'inode': info.st_ino,
                        'mtime_ns': info.st_mtime_ns}
    return values


def prepare(image, report):
    host = host_files()
    code = '''import hashlib,json,pathlib,sys
result={}
for name in sys.argv[1:]:
 p=pathlib.Path(name)
 assert p.is_file() and not p.is_symlink(), name
 with p.open('rb') as stream: sha=hashlib.file_digest(stream,'sha256').hexdigest()
 result[name]={'sha256':sha,'bytes':p.stat().st_size,'device':p.stat().st_dev,'inode':p.stat().st_ino}
print(json.dumps(result))
'''
    output = subprocess.check_output([
        'docker', 'run', '--rm', '--network', 'none', '--cpus', '1', '--memory', '512m',
        '--read-only', '--entrypoint', 'python3', image, '-B', '-c', code, *FILES,
    ], text=True, timeout=30)
    original = json.loads(output)
    for name in FILES:
        if any(host[name][field] != original[name][field] for field in ('sha256', 'bytes')):
            raise ValueError('Host/image system file differs; refusing mixed runtime: ' + name)
    report.write_text(json.dumps({'schema': 1, 'kind': 'shared-system-pages-diagnostic',
                                  'image': image, 'host': host, 'image_original': original,
                                  'mount_mode': 'readonly', 'product_changed': False}, indent=2) + '\n')
    mounts = []
    for name in FILES:
        mounts += ['--mount', f'type=bind,src={name},dst={name},readonly']
    return mounts, host


def verify_unchanged(before):
    if host_files() != before:
        raise ValueError('System files changed during diagnostic; result cannot be compared')
