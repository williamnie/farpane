#!/usr/bin/env python3
"""Check frozen Home navigation at two sizes/scales in a private software display."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--viewer-toolbar', action='store_true')
    args = parser.parse_args()
    artifact = args.artifact.resolve(strict=True)
    assert os.getuid() != 0 and artifact.parent == ROOT / 'Build/Linux/artifacts'
    sys.path.insert(0, str(ROOT / 'Linux/packaging'))
    import native_bundle
    native_bundle.verify(artifact)
    pin = json.loads((ROOT / 'Linux/dependencies.lock.json').read_text())['native_display_test']
    mode = 'viewer-toolbar' if args.viewer_toolbar else 'home-layout'
    parent = ROOT / ('Build/Linux/native-' + mode)
    parent.mkdir(exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    sources = ['Linux/tests/' + name for name in (
        'native_host_smoke.py', 'native_viewer_smoke.py', 'native_lifecycle_smoke.py',
        'native_home_layout.py', 'native_viewer_toolbar.py', 'native_layout_widgets.c', 'test_native_home_layout_guard.py',
        'native-lifecycle-layout.json')]
    sources += ['Linux/packaging/native_bundle.py', 'Linux/dependencies.lock.json',
                'Scripts/linux/test-native-home-layout.py']
    hashes = {}
    for name in sources:
        path = output / 'source' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, path)
        hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    name = 'farpane-layout-' + uuid.uuid4().hex[:12]
    artifact_inside = '/workspace/Build/Linux/artifacts/' + artifact.name
    command = ['docker', 'run', '--rm', '--name', name, '--network', 'none', '--read-only',
        '--cpus', '4', '--memory', '6g', '--pids-limit', '512', '--cap-drop', 'ALL',
        '--cap-add', 'CHOWN', '--cap-add', 'DAC_OVERRIDE', '--cap-add', 'FOWNER',
        '--cap-add', 'SETUID', '--cap-add', 'SETGID', '--security-opt', 'no-new-privileges',
        '--tmpfs', '/opt:rw,exec,mode=755,size=512m',
        '--tmpfs', '/tmp:rw,nosuid,nodev,mode=1777,size=256m',
        '--tmpfs', '/run/farpane-native-test:rw,nosuid,nodev,mode=755,size=256m',
        '--mount', f'type=bind,src={output}/source/Linux/tests,dst=/workspace/Linux/tests,readonly',
        '--mount', f'type=bind,src={output}/source/Linux/packaging,dst=/workspace/Linux/packaging,readonly',
        '--mount', f'type=bind,src={artifact},dst={artifact_inside},readonly',
        '--mount', f'type=bind,src={output},dst=/output',
        '-e', 'FARPANE_NATIVE_TEST_MODE=' + mode,
        '-e', 'FARPANE_NATIVE_TEST_ARTIFACT=' + artifact_inside,
        '-e', 'HOME=/run/farpane-native-test/user', '-e', 'PYTHONDONTWRITEBYTECODE=1',
        '--entrypoint', 'timeout', pin['image'], '--signal=TERM', '--kill-after=10', '200',
        'python3', '-B', '/workspace/Linux/tests/native_viewer_smoke.py', '/output/run',
        str(os.getuid()), str(os.getgid())]
    inputs = {'image': pin['image'], 'artifact': artifact.name, 'sources': hashes,
        'manifest_sha256': hashlib.sha256((artifact / 'manifest.json').read_bytes()).hexdigest(),
        'command': command}
    (output / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
    print(output, flush=True)
    with (output / 'runner.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=220)
        finally:
            if process.poll() is None:
                subprocess.run(['docker', 'rm', '-f', name], stdout=log,
                               stderr=subprocess.STDOUT, timeout=10, check=False)
                process.wait(timeout=10)
    (output / 'exit.json').write_text(json.dumps({'returncode': code}) + '\n')
    if code:
        raise SystemExit(f'Layout check failed ({code}); see {output}/runner.log')
    report = json.loads((output / 'run' / (mode + '-result.json')).read_text())
    print(json.dumps({'output': str(output), 'result': report['result'], 'mode': mode}), flush=True)


if __name__ == '__main__':
    main()
