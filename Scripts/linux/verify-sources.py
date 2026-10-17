#!/usr/bin/env python3
"""Reconstruct every patched file from pinned objects and compare the build copy."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'Build/Linux'
LOCK = json.loads((ROOT / 'Linux/dependencies.lock.json').read_text())
spec = importlib.util.spec_from_file_location('prepare', ROOT / 'Scripts/linux/prepare.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reference', type=Path, required=True)
args = parser.parse_args()
reference = args.reference.resolve()
hw = list((reference / 'cache/cargo/git/checkouts').glob('hwcodec-*/' + LOCK['hwcodec']['commit'][:7]))
if len(hw) != 1:
    raise SystemExit('Expected exactly one pinned read-only hwcodec object cache')
origins = {'rustdesk': reference / 'rustdesk', 'hwcodec': hw[0]}
clipboard_pin = LOCK['clipboard_master']['commit'][:7]
clipboard_caches = list((BUILD / 'cargo/git/checkouts').glob('clipboard-master-*/' + clipboard_pin))
clipboard_caches += list((reference / 'cache/cargo/git/checkouts').glob('clipboard-master-*/' + clipboard_pin))
origins['clipboard_master'] = next(iter(clipboard_caches), BUILD / 'git/clipboard_master')
ffmpeg_name = 'ffmpeg-' + LOCK['ffmpeg']['version']
report = []
with tempfile.TemporaryDirectory(dir=BUILD) as temp:
    for target in ('rustdesk', 'hwcodec', 'ffmpeg', 'clipboard_master'):
        entries = [e for e in LOCK['patches'] if e.get('target', 'rustdesk') == target]
        paths = set()
        for entry in entries:
            patch = ROOT / entry['path']
            prepare.checked_file(patch, entry['sha256'])
            paths.update(re.findall(r'^--- a/(.+)$', patch.read_text(), re.M))
        tree = Path(temp) / target
        tree.mkdir()
        for name in sorted(paths):
            file = tree / name
            file.parent.mkdir(parents=True, exist_ok=True)
            if target == 'ffmpeg':
                with tarfile.open(BUILD / 'downloads' / (ffmpeg_name + '.tar.xz')) as archive:
                    data = archive.extractfile(ffmpeg_name + '/' + name).read()
            else:
                origin = origins[target]
                revision = LOCK[target]['commit']
                object_path = name
                # hbb_common is a separately pinned submodule, populated before
                # applying the RustDesk-tree patches by prepare.py.
                if target == 'rustdesk' and name.startswith('libs/hbb_common/'):
                    origin = reference / 'rustdesk/libs/hbb_common'
                    revision = LOCK['hbb_common']['commit']
                    object_path = name.removeprefix('libs/hbb_common/')
                data = subprocess.check_output(['git', '-c', f'safe.directory={origin}', '-C', str(origin),
                                                'show', revision + ':' + object_path])
            file.write_bytes(data)
        for entry in entries:
            prepare.apply_patch(tree, ROOT / entry['path'])
        for name in sorted(paths):
            actual = BUILD / 'src' / (ffmpeg_name if target == 'ffmpeg' else target) / name
            expected = (tree / name).read_bytes()
            if actual.read_bytes() != expected:
                raise SystemExit(f'Canonical patch/source mismatch: {actual}')
            report.append({'target': target, 'file': name, 'sha256': hashlib.sha256(expected).hexdigest()})
for entry in LOCK['lockfiles']:
    prepare.checked_file(ROOT / entry['path'], entry['sha256'])
    relative = 'Cargo.lock' if entry['path'].endswith('/Cargo.lock') else 'flutter/pubspec.lock'
    prepare.checked_file(BUILD / 'src/rustdesk' / relative, entry['sha256'])
for entry in LOCK.get('overlays', []):
    prepare.checked_file(ROOT / entry['path'], entry['sha256'])
    prepare.checked_file(BUILD / 'src/rustdesk' / entry['target'], entry['sha256'])
    report.append({'target': 'rustdesk', 'file': entry['target'], 'sha256': entry['sha256']})
print(json.dumps({'patched_files': report, 'lockfiles': 'match', 'result': 'PASS'}, indent=2))
