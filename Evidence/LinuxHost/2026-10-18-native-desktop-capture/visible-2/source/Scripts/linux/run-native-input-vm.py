#!/usr/bin/env python3
"""Boot only the owned guest disk; no network, host input, display or GPU."""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
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
    parser.add_argument('disk', type=Path, help='Prepared disk.* directory under Build/Linux/native-input-vm')
    args = parser.parse_args()
    disk = args.disk.resolve(strict=True)
    assert disk.is_relative_to(BUILD) and (disk / 'disk.json').is_file()
    pin = json.loads((ROOT / 'Linux/tests/native-input-vm.lock.json').read_text())
    disk_info = json.loads((disk/'disk.json').read_text())
    assert disk_info['runtime_image'] == pin['image']
    kernel = BUILD / ('vmlinuz-' + pin['kernel']['version'])
    config = BUILD / ('kernel-config-' + pin['kernel']['version'])
    assert digest(kernel) == pin['kernel']['sha256']
    assert digest(config) == pin['kernel']['config_sha256']
    for feature in ('INPUT_UINPUT', 'INPUT_EVDEV', 'VIRTIO_BLK', 'VIRTIO_PCI',
                    'EXT4_FS', 'DEVTMPFS', 'SERIAL_8250_CONSOLE'):
        assert re.search(r'^CONFIG_' + feature + '=y$', config.read_text(), re.M), feature
    with (BUILD / '.vm-test.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        output = Path(tempfile.mkdtemp(prefix='run.', dir=BUILD))
        name = 'farpane-input-vm-' + uuid.uuid4().hex[:12]
        common = ['docker', 'run', '--rm', '--network', 'none', '--cpus', str(pin['cpus']),
                  '--memory', pin['container_memory'], '--pids-limit', '256', '--read-only',
                  '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
                  '--user', f'{os.getuid()}:{os.getgid()}',
                  '--mount', f'type=bind,src={disk},dst=/disk,readonly',
                  '--mount', f'type=bind,src={kernel},dst=/input/kernel,readonly',
                  '--mount', f'type=bind,src={output},dst=/output',
                  '--tmpfs', '/tmp:rw,nosuid,nodev,size=256m']
        subprocess.run([*common, '--entrypoint', 'qemu-img', pin['image'],
                        'create', '-f', 'qcow2', '-F', 'raw', '-b', '/disk/guest-root.raw',
                        '/output/guest.qcow2'], check=True, capture_output=True, timeout=10)
        command = [*common, '--name', name, '--device', '/dev/kvm:/dev/kvm:rw',
                   '--group-add', str(Path('/dev/kvm').stat().st_gid),
                   '--entrypoint', 'qemu-system-x86_64', pin['image'],
                   '-machine', 'q35,accel=kvm', '-cpu', 'host', '-smp', str(pin['cpus']),
                   '-m', str(pin['guest_memory_mib']), '-nodefaults', '-display', 'none',
                   '-serial', 'file:/output/serial.log', '-monitor', 'none', '-nic', 'none',
                   '-no-reboot', '-kernel', '/input/kernel',
                   '-drive', 'file=/output/guest.qcow2,if=virtio,format=qcow2',
                   '-append', 'root=/dev/vda rw console=ttyS0,115200n8 '
                   'init=/opt/farpane-input-test/init.py panic=1 oops=panic farpane.input-vm=1'
                   + (' systemd.show_status=false loglevel=3' if disk_info['stage']=='desktop' else '')]
        host_boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        (output / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
        print('private_input_vm_output=' + str(output), flush=True)
        with (output / 'qemu.log').open('w') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            try:
                code = process.wait(timeout=300 if disk_info.get('scenario')=='maintenance' else pin['wall_seconds'])
            finally:
                if process.poll() is None:
                    subprocess.run(['docker', 'rm', '-f', name], check=False, timeout=10)
                    process.wait(timeout=10)
        serial = (output / 'serial.log').read_text(errors='replace')
        matches = re.findall(r'^FARPANE_INPUT_VM_RESULT=(.+)$', serial, re.M)
        assert len(matches) == 1, 'No unique guest result; inspect serial.log/qemu.log'
        guest = json.loads(matches[0])
        assert guest['boot_id'] != host_boot, 'Guest must use a separate kernel instance'
        if disk_info.get('desktop_launch_probe') or disk_info.get('desktop_lifecycle_probe'):
            pictures=re.findall(r'^VM_IMAGE (launch-[a-z0-9-]+\.png) ([A-Za-z0-9+/=]+)\r?$',serial,re.M)
            if disk_info.get('desktop_shell_observer'):
                assert disk_info.get('desktop_launch_probe') is True
                limit=14  # Three Shell/VKMS pairs in addition to eight launch images.
            else:
                limit=10 if disk_info.get('desktop_lifecycle_probe') else 8
            assert len(pictures)<=limit and len({name for name,_ in pictures})==len(pictures)
            for filename,encoded in pictures:
                assert len(encoded)<=1400000
                data=base64.b64decode(encoded,validate=True)
                assert data.startswith(b'\x89PNG\r\n\x1a\n') and len(data)<=1024*1024
                (output/filename).write_bytes(data)
        result = {'result': 'pass' if code == 0 and guest['result'] == 'pass' else 'fail',
                  'runtime_image': pin['image'],
                  'kernel_sha256': pin['kernel']['sha256'], 'guest': guest,
                  'separate_kernel_verified': True, 'network': 'none',
                  'host_devices_exposed': ['/dev/kvm'], 'host_display': False,
                  'real_farpane_input_accepted': False}
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result), flush=True)
        if result['result'] != 'pass':
            raise RuntimeError('Private VM regression failed; inspect result.json and serial.log')


if __name__ == '__main__':
    main()
