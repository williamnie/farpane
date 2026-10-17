"""Freeze the completed published-crate investigation without running products."""
import ast
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
os.chdir(ROOT)
sys.path.insert(0, str(ROOT/'Linux/packaging'))
import native_receipt

OLD = ROOT/'Evidence/LinuxHost/2026-10-17-native-notice-delivery'
OUT = ROOT/'Evidence/LinuxHost/2026-10-17-native-published-notices'
RAW = ROOT/'Build/Linux/legacy-notices'

def read(path):
    return json.loads(Path(path).read_text())

def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def save(name, value):
    with (OUT/name).open('x') as stream:
        stream.write(json.dumps(value, indent=2, ensure_ascii=False)+'\n')

def command(*args):
    return subprocess.check_output(args, text=True)

assert sorted(p.name for p in OUT.iterdir()) == ['README.md']
pins = read(ROOT/'Linux/native-published-notices.json')
verification = read(RAW/'verification.json')
assert verification['result'] == 'pass'
assert verification['pins_sha256'] == sha(ROOT/'Linux/native-published-notices.json')
assert len(verification['new_followups']) == 2
assert [p['published_files_verified'] for p in verification['new_followups']] == [6,6]
assert verification['full_notice_location_followups_including_addendum'] == 28
assert verification['baseline_records_without_full_notice_followup'] == 17
rejections = read(RAW/'rejection-checks.json')
assert len(rejections) == 7
assert rejections[0]['result'] == 'pass'
assert all(p['result'] == 'rejected-as-expected' for p in rejections[1:])
bindings = read(RAW/'bindings.json')
assert [len(p['published_files']) for p in bindings] == [6,6,9]
assert all(not p['mismatches'] for p in bindings)
assert bindings[2]['notices'] == []
tags = read(RAW/'tags-summary.json')
assert next(p for p in tags if p['repo']=='quadrupleslap/repng')['error'] == 'HTTP Error 404: Not Found'
assert sha(ROOT/'Linux/native-notice-supplements.json') == pins['existing_supplement_pins_sha256']
audit = ROOT/'Build/Linux/source-audit'/('native-source-audit-'+pins['baseline_audit_sha256'][:24])/'report.json'
assert sha(audit) == pins['baseline_audit_sha256']

deliverables = read(OLD/'deliverables.json')
for entry in deliverables:
    path = ROOT/entry['path']
    assert path.stat().st_size == entry['bytes'] and sha(path) == entry['sha256'], str(path)
save('deliverables-unchanged.json', {'result':'pass', 'baseline':str(OLD.relative_to(ROOT)), 'files':deliverables})
receipt = native_receipt.verify(ROOT/'Build/Linux/native-build.json')
assert sha(ROOT/'Build/Linux/native-build.json') == sha(OLD/'native-build.json')
artifact = ROOT/'Build/Linux/artifacts'/pins['artifact_id']
build = read(artifact/'build.json')
old_build = read(OLD/'bundle-build.json')
assert build == old_build
for name, entry in build['packaged_binaries'].items():
    assert sha(artifact/name) == entry['sha256']
save('programs-unchanged.json', {'result':'pass', 'receipt_sha256':sha(ROOT/'Build/Linux/native-build.json'),
     'canonical_application_source_count':len(receipt['sources']), 'raw_binaries':receipt['binaries'],
     'packaged_binaries':{n:e['sha256'] for n,e in build['packaged_binaries'].items()}})

baseline = read(OLD/'host-state.json')
host = {'observed_at_utc':datetime.now(timezone.utc).isoformat(),
        'branch':command('git','branch','--show-current').strip(),
        'head':command('git','rev-parse','HEAD').strip(),
        'current':os.readlink('/opt/farpane/current'),
        'services':command('systemctl','show','farpane.service','rustdesk.service','-p','Id','-p','ActiveState','-p','UnitFileState','-p','MainPID'),
        'ffmpeg_static_archives_unchanged':{}}
for key in ['branch','head','current']:
    assert host[key] == baseline[key], key
assert sorted(host['services'].splitlines()) == sorted(baseline['services'].splitlines())
for name, entry in baseline['ffmpeg_static_archives_unchanged'].items():
    path = ROOT/name
    actual = {'bytes':path.stat().st_size,'mtime_ns':path.stat().st_mtime_ns,'sha256':sha(path)}
    assert actual == entry, name
    host['ffmpeg_static_archives_unchanged'][name] = actual
save('host-state.json', host)
containers = [json.loads(line) for line in command('docker','ps','--format','{{json .}}').splitlines()]
keys = ('ID','Image','Names','State')
def compact(items):
    return sorted([{k:x[k] for k in keys} for x in items], key=lambda x:x['ID'])
assert compact(containers) == compact(read(OLD/'containers.json'))
save('containers.json',compact(containers))

canonical = [Path(n) for n in (
    'Linux/native-published-notices.json', 'Linux/packaging/native_published_notices.py',
    'Scripts/linux/verify-published-notices.py', 'Linux/docs/published-crate-notices.md',
    'Linux/docs/native-source-materials.md', 'Linux/docs/gui-status.md')]
canonical += [Path(p['tree_path']) for p in pins['packages']]
for pin in pins['packages']:
    assert sha(ROOT/pin['tree_path']) == pin['tree_sha256']
for name in canonical:
    source = ROOT/name
    if source.suffix == '.py': ast.parse(source.read_text(), filename=str(name))
    target = OUT/'canonical'/name
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(source,target)
    assert sha(source) == sha(target)
links_checked = 0
for name in [n for n in canonical if n.suffix=='.md'] + [OUT.relative_to(ROOT)/'README.md']:
    path = ROOT/name
    for target in re.findall(r'\]\(([^)]+)\)', path.read_text()):
        if '://' in target or target.startswith('#'): continue
        target = target.split('#',1)[0]
        assert (path.parent/target).exists(), (str(path), target)
        links_checked += 1
subprocess.run(['git','diff','--check'], check=True)
shutil.copytree(RAW, OUT/'raw')
for name in ['verification.json','rejection-checks.json']:
    shutil.copy2(RAW/name, OUT/name)
save('final-check.json', {'result':'pass', 'canonical_sha256':{str(n):sha(ROOT/n) for n in canonical},
     'source_match_file_counts':[6,6,9], 'new_notice_followups':2, 'full_notice_location_followups_including_addendum':28,
     'baseline_records_without_full_notice_followup':17, 'copied_crate_validation_cases':7,
     'doc_links_checked':links_checked, 'candidate_deliverables_unchanged':True,
     'application_sources_and_binaries_unchanged':True, 'existing_supplement_pins_and_original_audit_unchanged':True,
     'host_services_containers_and_ffmpeg_unchanged':True, 'core_gui_media_rebuilt':False,
     'new_binary_package':False, 'product_executed':False, 'installed':False,
     'complete_license_source_audit':False, 'full_plan_acceptance':False})
files = sorted(p for p in OUT.rglob('*') if p.is_file())
with (OUT/'SHA256SUMS').open('x') as stream:
    for path in files: stream.write(sha(path)+'  '+path.relative_to(OUT).as_posix()+'\n')
for line in (OUT/'SHA256SUMS').read_text().splitlines():
    digest, name = line.split('  ',1)
    assert sha(OUT/name) == digest
print(json.dumps({'result':'pass','evidence':str(OUT.relative_to(ROOT)), 'indexed_files':len(files),
                  'canonical_files':len(canonical),'doc_links_checked':links_checked}))
