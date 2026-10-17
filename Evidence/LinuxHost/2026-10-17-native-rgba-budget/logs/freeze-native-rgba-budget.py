"""Freeze current RGBA proof and candidate metadata, excluding image payloads."""
import hashlib
import json
from pathlib import Path
import shutil

root = Path('/home/user/farpane')
out = root / 'Evidence/LinuxHost/2026-10-17-native-rgba-budget'
out.mkdir(exist_ok=False)

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def copy(path, target):
    assert path.is_file() and not path.is_symlink()
    target = out / target
    target.parent.mkdir(parents=True, exist_ok=True)
    assert not target.exists()
    shutil.copyfile(path, target)
    assert digest(path) == digest(target)

for p in sorted((root / 'Build/Linux/gui-work').glob('native-rgba-budget-*')):
    if p.suffix in ('.log', '.json', '.rs'):
        copy(p, Path('logs') / p.name)
copy(Path(__file__), 'logs/freeze-native-rgba-budget.py')
excluded = []
for date in ['20261017T035210Z', '20261017T035316Z', '20261017T035826Z']:
    base = root / 'Build/Linux/native-rgba-smoke' / date
    for p in sorted(base.iterdir()):
        if p.suffix in ('.log', '.json'):
            copy(p, Path('rgba-runs') / date / p.name)
        elif p.suffix == '.png':
            excluded.append({'source': p.relative_to(root).as_posix(),
                             'bytes': p.stat().st_size, 'sha256': digest(p)})
for category, dates in [
    ('native-viewer-smoke', ['20261017T040719Z', '20261017T040842Z']),
    ('native-package-smoke', ['20261017T040808Z', '20261017T040825Z']),
]:
    for date in dates:
        base = root / 'Build/Linux' / category / date
        for p in sorted(base.rglob('*')):
            if not p.is_file() or p.is_symlink():
                continue
            rel = p.relative_to(base)
            simple = (len(rel.parts) == 1 or
                      (len(rel.parts) == 2 and rel.parts[0] in ('viewer-0', 'viewer-1', 'viewer')) or
                      (len(rel.parts) == 3 and rel.parts[0] == 'viewer' and rel.parts[1] in ('viewer-0', 'viewer-1')))
            if simple and (p.suffix in ('.json', '.log', '.jsonl') or p.name in ('os-release.txt', 'runtime-packages.txt')):
                copy(p, Path('runs') / category / date / rel)
            elif simple and p.suffix in ('.png', '.bin'):
                excluded.append({'source': p.relative_to(root).as_posix(),
                                 'bytes': p.stat().st_size, 'sha256': digest(p)})
source_test = root / 'Build/Linux/native-source-smoke/20261017T041112Z'
assert json.loads((source_test / 'result.json').read_text())['result'] == 'pass'
for p in sorted(source_test.iterdir()):
    if p.is_file() and p.suffix in ('.json', '.stdout', '.stderr'):
        copy(p, Path('source-smoke') / p.name)
source = root / 'Build/Linux/source-bundles/farpane-native-source-6464d1ae0ddf72e154ec4431'
for name in ['source-manifest.json', 'binary-build-receipt.json']:
    copy(source / name, name)
notices = source / 'native-dependencies/notice-supplements'
for p in sorted(notices.rglob('*')):
    if p.is_file():
        copy(p, Path('notice-supplements') / p.relative_to(notices))
copy(root / 'Build/Linux/source-audit/native-source-audit-922c135abe0f176e0d2fb25f/report.json', 'source-audit-report.json')
bundle = root / 'Build/Linux/artifacts/farpane-native-dev-5449206e830476baad6031d4'
for name in ['build.json', 'manifest.json']:
    copy(bundle / name, Path('bundle') / name)
copy(root / 'Build/Linux/native-build.json', 'native-build.json')
(out / 'excluded-payloads.json').write_text(json.dumps(excluded, indent=2) + '\n')
print(json.dumps({'evidence': str(out), 'files': sum(p.is_file() for p in out.rglob('*')),
                  'excluded_test_payloads': len(excluded)}))
