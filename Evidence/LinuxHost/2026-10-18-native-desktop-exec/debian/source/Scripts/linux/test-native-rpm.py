#!/usr/bin/env python3
"""Test RPM install/upgrade/remove and actual GUI sessions off the host desktop."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('first', type=Path)
    parser.add_argument('upgrade', type=Path)
    args = parser.parse_args()
    if os.getuid() == 0:
        parser.error('Run the container launcher as an ordinary user')
    packages = [p.resolve(strict=True) for p in (args.first, args.upgrade)]
    if not all(p.is_relative_to(ROOT / 'Build/Linux/rpm') and p.is_file() and p.suffix == '.rpm'
               for p in packages) or packages[0] == packages[1]:
        parser.error('Provide distinct frozen RPM files under Build/Linux/rpm')
    pin = json.loads((ROOT / 'Linux/tests/native-runtime-images.lock.json').read_text())['fedora44']
    parent = ROOT / 'Build/Linux/native-rpm-smoke'
    parent.mkdir(exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    relative = output.relative_to(ROOT)
    command = ['docker', 'run', '--rm', '--init', '--network', 'none', '--cpus', '4',
               '--memory', '12g', '--pids-limit', '512', '--security-opt', 'no-new-privileges',
               '--tmpfs', '/opt:rw,exec,mode=755,size=1g',
               '--tmpfs', '/run/farpane-native-test:rw,mode=755,size=512m',
               '--env', 'PYTHONDONTWRITEBYTECODE=1',
               '--mount', f'type=bind,src={ROOT},dst=/workspace,readonly',
               '--mount', f'type=bind,src={output},dst=/workspace/{relative}',
               '--workdir', '/workspace', '--entrypoint', 'timeout', pin['image'],
               '--kill-after=10', '300', 'python3', '-B', '/workspace/Linux/tests/native_rpm_smoke.py',
               f'/workspace/{relative}/test', str(os.getuid()), str(os.getgid()),
               *['/workspace/' + str(p.relative_to(ROOT)) for p in packages]]
    (output / 'invocation.json').write_text(json.dumps({'command': command, 'runtime': pin}, indent=2) + '\n')
    print(str(output), flush=True)
    with (output / 'console.log').open('w') as stream:
        status = subprocess.call(command, stdout=stream, stderr=subprocess.STDOUT)
    (output / 'exit.json').write_text(json.dumps({'exit': status}) + '\n')
    print(json.dumps({'output': str(output), 'exit': status}), flush=True)
    raise SystemExit(status)


if __name__ == '__main__':
    main()
