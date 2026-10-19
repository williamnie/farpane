#!/usr/bin/env python3
"""Bounded Warp startup in an offline, empty-profile container; no host desktop."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

ROOT=Path(__file__).resolve().parents[2]


def main():
    pin=json.loads((ROOT/'Linux/tests/native-warp-test.lock.json').read_text())
    image=json.loads((ROOT/'Linux/tests/native-input-vm.lock.json').read_text())['image']
    for item in pin['files']:
        with Path(item['source']).open('rb') as stream:
            assert hashlib.file_digest(stream,'sha256').hexdigest()==item['sha256']
    # Some public packaged resources are mode 0600. Hash them as container
    # root, with only the read-only program tree exposed; no user data.
    manifest_code='''import hashlib,json
from pathlib import Path
root=Path('/input');rows=[]
for p in sorted(root.rglob('*')):
    if p.is_symlink():
        assert p.resolve().is_relative_to(root)
        rows.append([str(p.relative_to(root)),'symlink',str(p.readlink())])
    elif p.is_file():
        with p.open('rb') as f: sha=hashlib.file_digest(f,'sha256').hexdigest()
        rows.append([str(p.relative_to(root)),'file',p.stat().st_mode&511,p.stat().st_size,sha])
print(hashlib.sha256(json.dumps(rows,separators=(',',':')).encode()).hexdigest())
'''
    actual=subprocess.check_output(['docker','run','--rm','--network','none','--read-only',
        '--cpus','1','--memory','1g','--pids-limit','32',
        '--mount','type=bind,src=/opt/warpdotdev/warp-terminal,dst=/input,readonly',
        '--entrypoint','python3',image,'-B','-c',manifest_code],text=True,timeout=20).strip()
    assert actual==pin['program_manifest_sha256'], 'Public Warp installation changed'
    output=Path(tempfile.mkdtemp(prefix='warp-bootstrap.',dir=ROOT/'Build/Linux/native-input-vm'))
    (output/'test-source.py').write_bytes((ROOT/'Linux/tests/native_warp_bootstrap.py').read_bytes())
    (output/'launcher-source.py').write_bytes(Path(__file__).read_bytes())
    name='farpane-warp-probe-'+uuid.uuid4().hex[:12]
    command=['docker','run','--rm','--name',name,'--network','none','--read-only',
        '--cap-drop','ALL','--security-opt','no-new-privileges','--user','1000:1000',
        '--cpus','4','--memory','4g','--pids-limit','256',
        '--mount','type=bind,src=/opt/warpdotdev/warp-terminal,dst=/opt/warpdotdev/warp-terminal,readonly',
        '--mount',f'type=bind,src={output}/test-source.py,dst=/test.py,readonly',
        '--mount',f'type=bind,src={output},dst=/output',
        '--tmpfs','/tmp:rw,nosuid,nodev,mode=1777,size=256m',
        '-e','HOME=/tmp/farpane-warp-home','-e','LD_LIBRARY_PATH=/opt/farpane-warp-libs',
        '-e','SSL_CERT_FILE=/opt/farpane-warp-libs/root.pem']
    for item in pin['files'][1:]:
        command+=['--mount',f'type=bind,src={item["source"]},dst={item["destination"]},readonly']
    binary_sha=None
    if len(sys.argv)>1:
        binary=Path(sys.argv[1]).resolve(strict=True)
        assert binary.is_relative_to(ROOT/'Build/Linux/target')
        with binary.open('rb') as stream:binary_sha=hashlib.file_digest(stream,'sha256').hexdigest()
        command+=['--mount',f'type=bind,src={binary},dst=/opt/farpane-warp-test,readonly',
                  '-e','FARPANE_WARP_PRODUCTION_TEST_BINARY=/opt/farpane-warp-test']
    command+=['--entrypoint','timeout',image,'75','python3','-B','/test.py']
    (output/'command.json').write_text(json.dumps(command,indent=2)+'\n')
    (output/'inputs.json').write_text(json.dumps({'image':image,'program':pin,'test_binary_sha256':binary_sha,
        'test_sha256':hashlib.sha256((ROOT/'Linux/tests/native_warp_bootstrap.py').read_bytes()).hexdigest()},indent=2)+'\n')
    print(output,flush=True)
    with (output/'runner.log').open('w') as log:
        process=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT)
        try:
            code=process.wait(timeout=90)
        finally:
            if process.poll() is None:
                subprocess.run(['docker','rm','-f',name],stdout=log,stderr=subprocess.STDOUT,timeout=5,check=False)
                process.wait(timeout=5)
    assert code==0, f'Probe failed; see {output}/runner.log'
    print((output/'report.json').read_text())
    if binary_sha:assert json.loads((output/'report.json').read_text())['production']['returncode']==0


if __name__=='__main__':main()
