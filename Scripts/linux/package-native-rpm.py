#!/usr/bin/env python3
"""Package the frozen native artifact inside the pinned Fedora packaging image."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--version', required=True)
    parser.add_argument('--release', default='1.fc44')
    parser.add_argument('--inside', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    artifact = args.artifact.resolve(strict=True)
    if not artifact.is_relative_to(ROOT / 'Build/Linux/artifacts'):
        parser.error('Expected a frozen Build/Linux/artifacts bundle')
    output = ROOT / 'Build/Linux/rpm'
    if args.inside:
        sys.path.insert(0, str(ROOT / 'Linux/packaging'))
        import native_rpm
        result = native_rpm.build(artifact, args.version, args.release, output)
        receipt = output / (Path(result['package']).name + '.json')
        value = json.dumps(result, indent=2) + '\n'
        if receipt.exists() and receipt.read_text() != value:
            raise ValueError('Refusing to overwrite a different RPM receipt')
        receipt.write_text(value)
        print(value)
        return
    if os.getuid() == 0:
        parser.error('Start the packaging runner as an ordinary user')
    pin = json.loads((ROOT / 'Linux/tests/native-runtime-images.lock.json').read_text())['fedora44_rpm_builder']
    output.mkdir(exist_ok=True)
    privacy = Path(os.environ.get('FARPANE_PRIVACY_PATTERNS', str(Path.home() / '.config/farpane-private-patterns')))
    privacy_mount = []
    if privacy.is_file():
        privacy_mount = ['--mount', f'type=bind,src={privacy.resolve()},dst=/privacy/patterns,readonly',
                         '--env', 'FARPANE_PRIVACY_PATTERNS=/privacy/patterns']
    command = ['docker', 'run', '--rm', '--init', '--network', 'none', '--cpus', '4', '--memory', '12g',
               '--pids-limit', '256', '--read-only', '--cap-drop', 'ALL',
               '--security-opt', 'no-new-privileges', '--user', f'{os.getuid()}:{os.getgid()}',
               '--tmpfs', '/tmp:rw,nosuid,nodev,mode=1777,size=256m',
               '--env', 'HOME=/tmp', '--env', 'PYTHONDONTWRITEBYTECODE=1', *privacy_mount,
               '--mount', f'type=bind,src={ROOT},dst=/workspace,readonly',
               '--mount', f'type=bind,src={output},dst=/workspace/Build/Linux/rpm',
               '--workdir', '/workspace', '--entrypoint', 'timeout', pin['image'],
               '--kill-after=10', '240', 'python3', '-B', '/workspace/Scripts/linux/package-native-rpm.py',
               '/workspace/' + str(artifact.relative_to(ROOT)), '--version', args.version,
               '--release', args.release, '--inside']
    raise SystemExit(subprocess.call(command))


if __name__ == '__main__':
    main()
