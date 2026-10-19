#!/usr/bin/env python3
"""Private X11 selector integration, with no workstation devices or sockets."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root=Path(__file__).resolve().parents[2]
binary=Path(sys.argv[1]).resolve(strict=True)
assert binary.is_relative_to(root/'Build/Linux/target')
output=Path(tempfile.mkdtemp(prefix='paste-selector.',dir=root/'Build/Linux/native-input-vm'))
image=json.loads((root/'Linux/tests/native-input-vm.lock.json').read_text())['image']
command=['docker','run','--rm','--network','none','--read-only','--cpus','4','--memory','4g',
    '--pids-limit','128','--cap-drop','ALL','--security-opt','no-new-privileges','--user','1000:1000',
    '--mount',f'type=bind,src={root},dst=/workspace,readonly',
    '--mount',f'type=bind,src={output},dst=/output',
    '--tmpfs','/tmp:rw,nosuid,nodev,mode=1777,size=128m','--entrypoint','timeout',image,'35',
    'python3','-B','/workspace/Linux/tests/native_paste_target_test.py',
    '/workspace/'+str(binary.relative_to(root)),'/output']
(output/'command.json').write_text(json.dumps(command,indent=2)+'\n')
with binary.open('rb') as stream:sha=hashlib.file_digest(stream,'sha256').hexdigest()
(output/'inputs.json').write_text(json.dumps({'binary_sha256':sha,'test_sha256':hashlib.sha256(
    (root/'Linux/tests/native_paste_target_test.py').read_bytes()).hexdigest()},indent=2)+'\n')
print(output,flush=True)
with (output/'test.log').open('w') as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
