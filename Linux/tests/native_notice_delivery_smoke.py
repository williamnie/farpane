"""Verify a delivered source snapshot's notice export with no original caches."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys

assert Path('/.dockerenv').is_file() and os.geteuid() != 0
assert socket.if_nameindex() == [(1, 'lo')]
assert not Path('/workspace/Linux').exists() and not Path('/workspace/.git').exists()
assert not Path('/workspace/Build/Linux/cargo').exists() and not Path('/source/.git').exists()
assert not Path('/source/Build/Linux/cargo').exists()
assert not Path('/dev/dri').exists()
source = Path('/source')
output = Path(sys.argv[1])
sys.path.insert(0, str(source/'Linux/packaging'))
import native_notice_delivery as delivery

receipt = json.loads((source/'binary-build-receipt.json').read_text())
target = output/'exported-notices'
manifest = delivery.prepare(source, receipt['sources'], target)
frozen = source/'native-dependencies/notice-delivery'
assert (target/'manifest.json').read_bytes() == (frozen/'manifest.json').read_bytes()
result = subprocess.run(['python3', '-B', '-m', 'unittest', 'discover', '-s', 'Linux/tests',
                         '-p', 'test_native_notice_delivery.py'], cwd=source, capture_output=True, text=True)
(output/'unit-tests.stdout').write_text(result.stdout)
(output/'unit-tests.stderr').write_text(result.stderr)
assert result.returncode == 0, result.stderr
summary = {'result': 'pass', 'source_manifest_sha256': delivery.digest(source/'source-manifest.json'),
           'notice_manifest_sha256': delivery.digest(target/'manifest.json'),
           'material_files': len(manifest['files']), 'unit_tests': 12,
           'network': 'none', 'original_cargo_cache_visible': False, 'git_visible': False,
           'product_executed': False, 'binaries_recompiled': False, 'host_modified': False}
(output/'result.json').write_text(json.dumps(summary, indent=2)+'\n')
print(json.dumps(summary), flush=True)
