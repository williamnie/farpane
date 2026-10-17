#!/usr/bin/env python3
"""Copy pinned test servers from an already local image; no pull/service access."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
pin = json.loads((ROOT / 'Linux/tests/native-id-server.lock.json').read_text())
output = ROOT / 'Build/Linux/rendezvous-test-tools'


def verify(root):
    for name, entry in pin['files'].items():
        path = root / name
        assert path.is_file() and not path.is_symlink() and path.stat().st_size == entry['bytes']
        with path.open('rb') as stream:
            assert hashlib.file_digest(stream, 'sha256').hexdigest() == entry['sha256']


if output.exists():
    verify(output)
    print(json.dumps({'tools': str(output), 'verified_existing': True, 'image': pin['image']}))
else:
    # Use only this exact cached image. Never inspect/copy a running server.
    actual = subprocess.check_output(['docker', 'image', 'inspect', pin['image'], '--format', '{{.Id}}'], text=True).strip()
    assert actual == pin['image']
    with tempfile.TemporaryDirectory(dir=output.parent, prefix='.id-server-tools-') as work:
        root = Path(work)
        container = subprocess.check_output(['docker', 'create', '--network', 'none', '--entrypoint',
                                             'hbbs', pin['image'], '--help'], text=True).strip()
        try:
            process = subprocess.Popen(['docker', 'export', container], stdout=subprocess.PIPE)
            with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
                for member in archive:
                    for name, entry in pin['files'].items():
                        if member.name == entry['image_path']:
                            assert member.isfile() and not (root / name).exists()
                            with archive.extractfile(member) as source, (root / name).open('xb') as target:
                                shutil.copyfileobj(source, target)
                            (root / name).chmod(0o755)
            assert process.wait() == 0
            verify(root)
            (root / 'provenance.json').write_text(json.dumps(pin, indent=2) + '\n')
            root.chmod(0o755)
            root.rename(output)
        finally:
            subprocess.run(['docker', 'rm', container], check=True, stdout=subprocess.DEVNULL)
    print(json.dumps({'tools': str(output), 'verified_existing': False, 'image': pin['image']}))
