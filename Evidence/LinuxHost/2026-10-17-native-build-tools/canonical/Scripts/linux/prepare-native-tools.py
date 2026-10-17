#!/usr/bin/env python3
"""Prepare pinned public build tools without installing anything on the host."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Linux/packaging'))
import native_build_tools as build_tools


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--offline', action='store_true', help='Verify cached archives; never download')
    parser.add_argument('--fetch-only', action='store_true', help='Fetch/verify tools without creating an SDK')
    parser.add_argument('--cache', type=Path, default=ROOT / 'Build/Linux/native-tools/downloads')
    parser.add_argument('--image', default='farpane-native-source-builder:ubuntu2404')
    parser.add_argument('--reuse-sdk', type=Path, help='Verify an existing immutable SDK; do not reinstall')
    args = parser.parse_args()
    lock_path = ROOT / 'Linux/native-build-tools.lock.json'
    lock = build_tools.read_lock(lock_path)
    application = json.loads((ROOT / 'Linux/dependencies.lock.json').read_text())
    build_tools.require(lock['rust_version'] == application['builder']['rust'] and
                        lock['target'] == application['target'] and
                        lock['vcpkg_source_commit'] == application['vcpkg']['commit'],
                        'Build tool pins differ from application pins')
    cache = args.cache.resolve()
    build_tools.require(cache.is_relative_to(ROOT / 'Build'), 'Keep the tool cache under this source root Build/')
    report = build_tools.fetch(lock, cache, args.offline)
    if args.fetch_only:
        print(json.dumps({'result': 'pass', 'tools': report}, indent=2))
        return
    if args.reuse_sdk:
        sdk = args.reuse_sdk.resolve(strict=True)
        build_tools.require(sdk.is_relative_to(ROOT / 'Build'), 'Expected an owned Build/ SDK')
        build_tools.verify_sdk(sdk, lock_path)
    else:
        parent = ROOT / 'Build/Linux/native-tools'
        parent.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix='rust-sdk.', dir=parent))
        image_id = subprocess.check_output(['docker', 'image', 'inspect', args.image,
                                             '--format', '{{.Id}}'], text=True).strip()
        (output / 'builder-image-id.txt').write_text(image_id + '\n')
        (output / 'downloads.json').write_text(json.dumps(report, indent=2) + '\n')
        print('sdk_output=' + str(output), flush=True)
        command = ['docker', 'run', '--rm', '--network', 'none', '--cpus', '4', '--memory', '12g',
                   '--pids-limit', '512', '--user', f'{os.getuid()}:{os.getgid()}',
                   '--mount', f'type=bind,src={cache},dst=/inputs/cache,readonly',
                   '--mount', f'type=bind,src={lock_path},dst=/inputs/tools.lock.json,readonly',
                   '--mount', f'type=bind,src={ROOT}/Linux/packaging/native_build_tools.py,dst=/inputs/install.py,readonly',
                   '--mount', f'type=bind,src={output},dst=/output', '--workdir', '/output',
                   '--entrypoint', 'python3', args.image, '-B', '/inputs/install.py', 'install']
        (output / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
        with (output / 'install.log').open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
        sdk = output / 'sdk'
        build_tools.verify_sdk(sdk, lock_path)
    result = {'result': 'pass', 'sdk': str(sdk), 'tools': report,
              'sdk_receipt_sha256': build_tools.digest(sdk / 'toolchain-receipt.json'),
              'host_installed': False}
    if not args.reuse_sdk:
        (sdk.parent / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
