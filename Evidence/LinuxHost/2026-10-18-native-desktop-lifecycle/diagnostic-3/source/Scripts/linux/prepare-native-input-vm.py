#!/usr/bin/env python3
"""Prepare a private guest root disk from the pinned runtime image and bundle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'Build/Linux/native-input-vm'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--stage', choices=('bootstrap','service','viewer-notice','viewer','desktop'), default='service')
    parser.add_argument('--target', choices=('entry','terminal','browser'), default='entry')
    parser.add_argument('--input-driver', choices=('gtk','wire'), default='gtk')
    parser.add_argument('--maintenance-debs', nargs=2, type=Path, metavar=('FIRST', 'UPGRADE'),
                        help='Run package/systemd/desktop maintenance instead of input testing')
    desktop_probes = parser.add_mutually_exclusive_group()
    desktop_probes.add_argument('--desktop-launch-probe', action='store_true',
                        help='Compare real desktop launch methods using the upgraded frozen package')
    desktop_probes.add_argument('--desktop-lifecycle-probe', action='store_true',
                        help='Check GNOME single-instance, Alt-Tab, close and reopen using the frozen package')
    args = parser.parse_args()
    assert args.target=='entry' or args.stage=='desktop'
    assert args.input_driver=='gtk' or args.stage=='desktop'
    packages = []
    assert not (args.desktop_launch_probe or args.desktop_lifecycle_probe) or args.maintenance_debs
    if args.maintenance_debs:
        assert args.stage == 'desktop' and args.target == 'entry' and args.input_driver == 'gtk'
        packages = [p.resolve(strict=True) for p in args.maintenance_debs]
        assert packages[0] != packages[1]
        assert all(p.is_relative_to(ROOT/'Build/Linux/debian') and p.suffix=='.deb' for p in packages)
    artifact = args.artifact.resolve(strict=True)
    assert artifact.is_relative_to(ROOT / 'Build/Linux/artifacts')
    pin = json.loads((ROOT / 'Linux/tests/native-input-vm.lock.json').read_text())
    assert digest(ROOT / pin['dockerfile']) == pin['dockerfile_sha256']
    assert subprocess.check_output(['docker', 'image', 'inspect', pin['image'], '--format', '{{.Id}}'],
                                   text=True).strip() == pin['image']
    BUILD.mkdir(parents=True, exist_ok=True)
    cache = BUILD / 'cache' / pin['image'].split(':', 1)[1]
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / 'rootfs.tar'
    receipt = cache / 'rootfs.json'
    if archive.exists():
        record = json.loads(receipt.read_text())
        assert record['image'] == pin['image'] and record['sha256'] == digest(archive)
    else:
        container = subprocess.check_output(['docker', 'create', '--network', 'none', '--entrypoint',
                                             '/bin/true', pin['image']], text=True).strip()
        temporary = cache / 'rootfs-incomplete.tar'
        assert not temporary.exists()
        try:
            subprocess.run(['docker', 'export', '--output', str(temporary), container], check=True)
            record = {'image': pin['image'], 'sha256': digest(temporary)}
            receipt.write_text(json.dumps(record, indent=2) + '\n')
            temporary.rename(archive)
        finally:
            subprocess.run(['docker', 'rm', container], check=True, stdout=subprocess.DEVNULL)
    output = Path(tempfile.mkdtemp(prefix='disk.', dir=BUILD))
    name = 'farpane-input-disk-' + uuid.uuid4().hex[:12]
    command = ['docker', 'run', '--rm', '--name', name, '--network', 'none', '--cpus', '4', '--memory', '12g',
               '--pids-limit', '256',
               '--env', 'FARPANE_VM_DESKTOP_LAUNCH='+('1' if args.desktop_launch_probe else '0'),
               '--env', 'FARPANE_VM_DESKTOP_LIFECYCLE='+('1' if args.desktop_lifecycle_probe else '0'),
               '--mount', f'type=bind,src={ROOT},dst=/workspace,readonly',
               '--mount', f'type=bind,src={archive},dst=/input/rootfs.tar,readonly',
               '--mount', f'type=bind,src={output},dst=/output',
               *(['--mount','type=bind,src=/opt/google/chrome,dst=/input/chrome,readonly']
                 if args.target=='browser' else []),
               '--workdir', '/workspace', '--entrypoint', 'python3', pin['image'],
               '-B', '/workspace/Linux/tests/native_input_vm_prepare.py', '/output',
               str(os.getuid()), str(os.getgid()), '/workspace/' + artifact.relative_to(ROOT).as_posix(), args.stage, args.target,args.input_driver,
               *['/workspace/'+p.relative_to(ROOT).as_posix() for p in packages]]
    with (output / 'prepare.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            code = process.wait(timeout=180)
            if code:
                raise subprocess.CalledProcessError(code, command)
        finally:
            if process.poll() is None:
                subprocess.run(['docker','rm','-f',name],check=False,timeout=10,
                               stdout=log,stderr=subprocess.STDOUT)
                process.wait(timeout=10)
    record = json.loads((output / 'disk.json').read_text())
    assert record['rootfs_source_sha256'] == digest(archive)
    print(json.dumps({'directory': str(output), **record}), flush=True)


if __name__ == '__main__':
    main()
