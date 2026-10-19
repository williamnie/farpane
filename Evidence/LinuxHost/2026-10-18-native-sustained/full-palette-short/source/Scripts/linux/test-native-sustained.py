#!/usr/bin/env python3
"""Bounded continuous-session check using a frozen artifact, never a build."""
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
    parser.add_argument('--seconds', type=int, choices=(60, 1800), default=1800)
    args = parser.parse_args()
    artifact = args.artifact.resolve(strict=True)
    if artifact.parent != ROOT / 'Build/Linux/artifacts' or os.getuid() == 0:
        parser.error('Run as an ordinary user with a frozen Build/Linux/artifacts bundle')
    sys.path.insert(0, str(ROOT / 'Linux/packaging'))
    import native_bundle
    native_bundle.verify(artifact)
    image = json.loads((ROOT / 'Linux/dependencies.lock.json').read_text())['native_builder']['image']
    parent = ROOT / 'Build/Linux/native-sustained'
    parent.mkdir(exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    snapshot = output / 'source'
    files = ['Linux/tests/' + name for name in (
        'native_host_smoke.py', 'native_viewer_smoke.py', 'native_lifecycle_smoke.py',
        'native_sustained_smoke.py', 'native-lifecycle-layout.json')]
    files += ['Linux/packaging/native_bundle.py', 'Scripts/linux/test-native-sustained.py']
    hashes = {}
    for name in files:
        target = snapshot / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, target)
        hashes[name] = hashlib.sha256(target.read_bytes()).hexdigest()
    name = 'farpane-sustained-' + uuid.uuid4().hex[:12]
    artifact_inside = '/workspace/Build/Linux/artifacts/' + artifact.name
    command = ['docker', 'run', '--rm', '--name', name, '--network', 'none', '--read-only',
        '--cpus', '4', '--memory', '6g', '--pids-limit', '512', '--cap-drop', 'ALL',
        '--cap-add', 'CHOWN', '--cap-add', 'DAC_OVERRIDE', '--cap-add', 'FOWNER',
        '--cap-add', 'SETUID', '--cap-add', 'SETGID', '--security-opt', 'no-new-privileges',
        '--tmpfs', '/opt:rw,exec,mode=755,size=512m',
        '--tmpfs', '/tmp:rw,nosuid,nodev,mode=1777,size=256m',
        '--tmpfs', '/run/farpane-native-test:rw,nosuid,nodev,mode=755,size=256m',
        '--mount', f'type=bind,src={snapshot}/Linux/tests,dst=/workspace/Linux/tests,readonly',
        '--mount', f'type=bind,src={snapshot}/Linux/packaging,dst=/workspace/Linux/packaging,readonly',
        '--mount', f'type=bind,src={artifact},dst={artifact_inside},readonly',
        '--mount', f'type=bind,src={output},dst=/output',
        '-e', 'FARPANE_NATIVE_TEST_MODE=sustained',
        '-e', 'FARPANE_NATIVE_TEST_ARTIFACT=' + artifact_inside,
        '-e', 'FARPANE_SUSTAINED_SECONDS=' + str(args.seconds),
        '-e', 'HOME=/run/farpane-native-test/user', '-e', 'PYTHONDONTWRITEBYTECODE=1',
        '--entrypoint', 'timeout', image, '--signal=TERM', '--kill-after=10', str(args.seconds + 120),
        'python3', '-B', '/workspace/Linux/tests/native_viewer_smoke.py', '/output/run',
        str(os.getuid()), str(os.getgid())]
    inputs = {'image': image, 'container': name, 'artifact': artifact.name,
              'manifest_sha256': hashlib.sha256((artifact / 'manifest.json').read_bytes()).hexdigest(),
              'seconds': args.seconds, 'sources': hashes, 'command': command}
    (output / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
    print(output, flush=True)
    with (output / 'runner.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=args.seconds + 150)
        finally:
            if process.poll() is None:
                subprocess.run(['docker', 'rm', '-f', name], stdout=log, stderr=subprocess.STDOUT,
                               timeout=10, check=False)
                process.wait(timeout=10)
    (output / 'exit.json').write_text(json.dumps({'returncode': code}) + '\n')
    if code:
        raise SystemExit(f'Sustained check failed ({code}); see {output}/runner.log')
    print((output / 'run/sustained-result.json').read_text(), flush=True)


if __name__ == '__main__':
    main()
