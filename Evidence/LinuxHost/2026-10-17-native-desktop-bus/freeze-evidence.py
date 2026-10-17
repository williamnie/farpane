"""Archive the completed private-bus test and verify its exact scope."""
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
sys.path.insert(0,str(ROOT/'Linux/packaging'))
import native_receipt

OUT = ROOT/'Evidence/LinuxHost/2026-10-17-native-desktop-bus'
RUN = ROOT/'Build/Linux/native-desktop-bus-smoke/20261017T093347Z'
PREVIOUS = ROOT/'Evidence/LinuxHost/2026-10-17-native-published-notices'
DELIVERY = ROOT/'Evidence/LinuxHost/2026-10-17-native-notice-delivery'
ARTIFACT = ROOT/'Build/Linux/artifacts/farpane-native-dev-e7508f297ef1d671172d7737'

def load(path): return json.loads(Path(path).read_text())
def sha(path):
    with Path(path).open('rb') as f: return hashlib.file_digest(f,'sha256').hexdigest()
def command(*args): return subprocess.check_output(args,text=True)
def save(name,value):
    with (OUT/name).open('x') as f: f.write(json.dumps(value,indent=2,ensure_ascii=False)+'\n')

assert sorted(p.name for p in OUT.iterdir())==['README.md']
result = load(RUN/'desktop-bus-result.json')
assert result['result']=='pass' and len(set(result['checks']))==10
assert len(set(result['bus_ids']))==4
assert 24<result['approval_timeout_seconds_after_bus_loss']<40
build = load(DELIVERY/'bundle-build.json')
assert load(ARTIFACT/'build.json')==build
binaries = load(RUN/'test-binaries.json')
for name, digest in binaries.items():
    assert digest==build['packaged_binaries'][name]['sha256']==sha(ARTIFACT/name)
assert set(binaries)=={'farpane','libexec/farpane-core'}
for p in RUN.glob('provider-*.json'):
    assert not load(p)['errors']
assert not load(RUN/'provider-4.json')['notifications']
accepted, rejected = [load(RUN/name/'viewer.json') for name in ('approved-viewer','unanswered-viewer')]
assert accepted['presented'] and accepted['worker_reaped'] and accepted['frames']==2
assert not rejected['presented'] and rejected['worker_reaped'] and rejected['frames']==0
history = load(RUN/'desktop-history.json')
assert any(not s['desktop']['connected'] and any(c['authorized'] for c in s['inbound']) for s in history)
assert any(not s['desktop']['connected'] and any(not c['authorized'] for c in s['inbound']) for s in history)
assert history[-1]['desktop']['connected'] and not history[-1]['inbound']
receipt = native_receipt.verify(ROOT/'Build/Linux/native-build.json')
assert sha(ROOT/'Build/Linux/native-build.json')==sha(DELIVERY/'native-build.json')
deliverables = load(DELIVERY/'deliverables.json')
for d in deliverables:
    p=ROOT/d['path']; assert p.stat().st_size==d['bytes'] and sha(p)==d['sha256']
save('deliverables-unchanged.json',{'result':'pass','files':deliverables})

previous = load(PREVIOUS/'host-state.json')
host = {'observed_at_utc':datetime.now(timezone.utc).isoformat(),
        'branch':command('git','branch','--show-current').strip(),
        'head':command('git','rev-parse','HEAD').strip(),
        'current':os.readlink('/opt/farpane/current'),
        'services':command('systemctl','show','farpane.service','rustdesk.service','-p','Id','-p','ActiveState','-p','UnitFileState','-p','MainPID'),
        'ffmpeg_static_archives_unchanged':{}}
for key in ['branch','head','current']: assert host[key]==previous[key],key
assert sorted(host['services'].splitlines())==sorted(previous['services'].splitlines())
for name, entry in previous['ffmpeg_static_archives_unchanged'].items():
    p=ROOT/name
    actual={'bytes':p.stat().st_size,'mtime_ns':p.stat().st_mtime_ns,'sha256':sha(p)}
    assert actual==entry,name
    host['ffmpeg_static_archives_unchanged'][name]=actual
containers = [json.loads(line) for line in command('docker','ps','--format','{{json .}}').splitlines()]
keys=('ID','Image','Names','State')
containers=sorted([{k:c[k] for k in keys} for c in containers],key=lambda c:c['ID'])
assert containers==load(PREVIOUS/'containers.json')
host['containers']=containers
save('host-state.json',host)

canonical = [Path(p) for p in (
    'Linux/tests/native_desktop_bus_smoke.py','Linux/tests/native_viewer_smoke.py',
    'Scripts/linux/test-native-desktop-bus.sh','Linux/docs/desktop-bus-recovery.md',
    'Linux/docs/desktop-integration.md','Linux/docs/gui-status.md','Linux/docs/native-test-candidate.md')]
doc_links=0
for name in canonical+[OUT.relative_to(ROOT)/'README.md']:
    p=ROOT/name
    if p.suffix=='.py': ast.parse(p.read_text(),filename=str(p))
    if p.suffix=='.md':
        for target in re.findall(r'\]\(([^)]+)\)',p.read_text()):
            if '://' in target or target.startswith('#'): continue
            assert (p.parent/target.split('#',1)[0]).exists(),(str(p),target)
            doc_links+=1
for name in canonical:
    target=OUT/'canonical'/name; target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(ROOT/name,target)
    assert sha(target)==sha(ROOT/name)
subprocess.run(['git','diff','--check'],check=True)
subprocess.run(['bash','-n','Scripts/linux/test-native-desktop-bus.sh'],check=True)
shutil.copytree(RUN,OUT/'runtime')
shutil.copy2(ROOT/'Build/Linux/gui-work/desktop-bus-first.log',OUT/'run.log')
shutil.copy2(__file__,OUT/'freeze-evidence.py')
save('final-check.json',{'result':'pass','runtime':str(RUN.relative_to(ROOT)),
    'artifact_id':ARTIFACT.name,'checks':result['checks'],'tests_executed_once':True,
    'actual_software_video_sessions':1,'unanswered_sessions_with_zero_frames':1,
    'bus_instances':4,'bus_restart_count':3,'host_pid_in_private_container':result['host_pid'],
    'binaries':binaries,'application_sources_and_receipt_unchanged':True,
    'canonical_sha256':{str(p):sha(ROOT/p) for p in canonical},'doc_links_checked':doc_links,
    'host_services_containers_and_ffmpeg_unchanged':True,'new_package':False,
    'new_compilation':False,'host_installation':False,'gpu_test':False,
    'gui_own_session_bus_failure_tested':False,'real_desktop_tested':False,
    'complete_license_source_audit':False,'full_plan_acceptance':False})
files=sorted(p for p in OUT.rglob('*') if p.is_file())
with (OUT/'SHA256SUMS').open('x') as f:
    for p in files:f.write(sha(p)+'  '+p.relative_to(OUT).as_posix()+'\n')
for line in (OUT/'SHA256SUMS').read_text().splitlines():
    digest,name=line.split('  ',1); assert sha(OUT/name)==digest
print(json.dumps({'result':'pass','indexed_files':len(files),'doc_links_checked':doc_links,
                  'runtime_files':sum(p.is_file() for p in RUN.rglob('*')),'checks':len(result['checks'])}))
