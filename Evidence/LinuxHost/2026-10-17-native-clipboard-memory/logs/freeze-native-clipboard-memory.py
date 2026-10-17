"""Retain this phase's raw evidence; never copy test credentials or large payloads."""
import hashlib
import json
from pathlib import Path
import shutil

root = Path('/home/user/farpane')
out = root / 'Evidence/LinuxHost/2026-10-17-native-clipboard-memory'
out.mkdir(exist_ok=False)

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def copy(path, relative):
    assert path.is_file() and not path.is_symlink(), path
    destination = out / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    assert not destination.exists(), destination
    shutil.copyfile(path, destination)
    assert digest(path) == digest(destination)

work = root / 'Build/Linux/gui-work'
for p in sorted(work.glob('native-clipboard-memory-*')):
    if p.suffix in ('.json', '.log'):
        copy(p, Path('logs') / p.name)
for name in ['native-home-identity.log', 'native-home-identity-2.log',
             'verify-memory-source-archive.py', 'freeze-native-clipboard-memory.py']:
    copy(work / name, Path('logs') / name)

viewers = ['20261017T031704Z', '20261017T031800Z', '20261017T032240Z',
           '20261017T033007Z', '20261017T033343Z', '20261017T033351Z',
           '20261017T033418Z']
packages = ['20261017T033309Z', '20261017T033326Z']
excluded = []
for category, dates in [('native-viewer-smoke', viewers), ('native-package-smoke', packages)]:
    for date in dates:
        base = root / 'Build/Linux' / category / date
        for p in sorted(base.rglob('*')):
            if not p.is_file() or p.is_symlink():
                continue
            relative = p.relative_to(base)
            # Only outputs, never configuration, home or downloaded test files.
            allowed_dir = relative.parent == Path('.') or (
                relative.parts[0] in ('viewer-0', 'viewer-1', 'file-ui', 'host-clipboard-ui')
                and len(relative.parts) == 2
            ) or (relative.parts[0] == 'viewer' and (
                len(relative.parts) == 2 or (len(relative.parts) == 3 and relative.parts[1] in ('viewer-0', 'viewer-1'))
            ))
            if allowed_dir and p.suffix in ('.json', '.jsonl', '.log', '.txt'):
                copy(p, Path('runs') / category / date / relative)
            elif allowed_dir and (p.suffix in ('.png', '.bin', '.so') or p.name == 'clipboard-fixture'):
                excluded.append({'source': p.relative_to(root).as_posix(),
                                 'bytes': p.stat().st_size, 'sha256': digest(p)})

bundle = root / 'Build/Linux/artifacts/farpane-native-dev-90b070cf48653dfd5e5c4e24'
for name in ['build.json', 'manifest.json']:
    copy(bundle / name, Path('bundle') / name)
copy(root / 'Build/Linux/native-build.json', 'native-build.json')
snapshot = root / 'Build/Linux/source-bundles/farpane-native-source-3cfe49a30f85dc07724d4c67'
copy(snapshot / 'source-manifest.json', 'source-manifest.json')
copy(snapshot / 'binary-build-receipt.json', 'source-binary-build-receipt.json')
notice = snapshot / 'native-dependencies/notice-supplements'
for p in sorted(notice.rglob('*')):
    if p.is_file():
        copy(p, Path('source-notice-supplements') / p.relative_to(notice))
audit = root / 'Build/Linux/source-audit/native-source-audit-16d0d04b8be557b3ef2f84fa'
copy(audit / 'report.json', 'source-audit-report.json')
(out / 'excluded-payloads.json').write_text(json.dumps(excluded, indent=2) + '\n')
print(json.dumps({'evidence': str(out), 'files': sum(p.is_file() for p in out.rglob('*')),
                  'excluded_test_payloads': len(excluded)}))
