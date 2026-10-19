#!/usr/bin/python3
"""PID 1 of the private input-test VM; never run on the workstation."""
import ctypes
import fcntl
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import time
import traceback

MARKER = Path('/.farpane-input-vm')


def mount_filesystems():
    # Check these BEFORE any mount, device operation or poweroff call.
    assert os.getpid() == 1 and os.geteuid() == 0 and MARKER.is_file()
    assert json.loads(MARKER.read_text())['isolation'] == 'guest-kernel-uinput'
    subprocess.run(['mount', '-t', 'proc', 'proc', '/proc'], check=True)
    assert 'farpane.input-vm=1' in Path('/proc/cmdline').read_text().split()
    subprocess.run(['mount', '-t', 'sysfs', 'sysfs', '/sys'], check=True)
    # This pinned kernel mounts devtmpfs before init. Retain that mount; a
    # second mount is rejected by mount(8) and must not be silently ignored.
    mounts = [line.split(' - ', 1) for line in Path('/proc/self/mountinfo').read_text().splitlines()]
    dev = [after.split()[0] for before, after in mounts if before.split()[4] == '/dev']
    if not dev:
        subprocess.run(['mount', '-t', 'devtmpfs', 'devtmpfs', '/dev'], check=True)
    else:
        assert dev == ['devtmpfs'], dev
    subprocess.run(['mount', '-t', 'tmpfs', '-o', 'mode=755', 'tmpfs', '/run'], check=True)
    Path('/dev/pts').mkdir(exist_ok=True)
    subprocess.run(['mount', '-t', 'devpts', 'devpts', '/dev/pts'], check=True)
    Path('/tmp').chmod(0o1777)


def kernel_input_probe():
    """Actual uinput -> guest evdev, with no host input device exposed."""
    assert os.getpid() == 1 and os.geteuid() == 0 and MARKER.is_file()
    assert json.loads(MARKER.read_text())['isolation'] == 'guest-kernel-uinput'
    assert 'farpane.input-vm=1' in Path('/proc/cmdline').read_text().split()
    name = 'FarPane private VM kernel probe'
    descriptor = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    created = False
    try:
        fcntl.ioctl(descriptor, 0x40045564, 1)  # UI_SET_EVBIT(EV_KEY)
        fcntl.ioctl(descriptor, 0x40045565, 30)  # UI_SET_KEYBIT(KEY_A)
        setup = struct.pack('HHHH80sI', 3, 0x1234, 1, 1, name.encode(), 0)
        fcntl.ioctl(descriptor, 0x405c5503, setup)  # UI_DEV_SETUP
        fcntl.ioctl(descriptor, 0x5501)  # UI_DEV_CREATE
        created = True
        deadline = time.monotonic() + 5
        target = None
        while time.monotonic() < deadline:
            matches = [p for p in Path('/sys/class/input').glob('event*')
                       if (p / 'device/name').read_text().strip() == name]
            if len(matches) == 1:
                target = Path('/dev/input') / matches[0].name
                if not target.exists():
                    # devtmpfs normally creates it before udev policy runs.
                    major, minor = map(int, (matches[0] / 'dev').read_text().split(':'))
                    target.parent.mkdir(exist_ok=True)
                    os.mknod(target, 0o20600, os.makedev(major, minor))
                break
            time.sleep(.02)
        assert target is not None, 'Guest kernel did not expose an evdev node'
        event_fd = os.open(target, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        try:
            expected = [(1, 30, 1), (0, 0, 0), (1, 30, 0), (0, 0, 0)]
            wire = b''.join(struct.pack('llHHi', 0, 0, *event) for event in expected)
            assert os.write(descriptor, wire) == len(wire)
            received = bytearray()
            deadline = time.monotonic() + 2
            while len(received) < len(wire):
                ready, _, _ = select.select([event_fd], [], [], max(0, deadline-time.monotonic()))
                assert ready, 'Guest evdev did not receive the injected keys'
                received.extend(os.read(event_fd, 4096))
            size = struct.calcsize('llHHi')
            assert len(received) % size == 0
            events = [list(struct.unpack('llHHi', received[i:i+size])[2:])
                      for i in range(0, len(received), size)]
            assert events == [list(e) for e in expected], events
            return {'device_name': name, 'events': events, 'input_kernel': 'private-guest'}
        finally:
            os.close(event_fd)
    finally:
        if created:
            fcntl.ioctl(descriptor, 0x5502)  # UI_DEV_DESTROY
        os.close(descriptor)


def main():
    mount_filesystems()
    result = {'schema': 1, 'scope': 'isolated-kernel-bootstrap', 'result': 'fail',
              'full_farpane_input_tested': False, 'host_input_exposed': False}
    try:
        result.update(kernel=os.uname().release,
                      boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                      machine=Path('/sys/class/dmi/id/product_name').read_text().strip(),
                      cmdline=Path('/proc/cmdline').read_text().strip())
        assert not Path('/dev/kvm').exists(), 'Nested KVM is not needed inside the guest'
        marker = json.loads(MARKER.read_text())
        if marker.get('scenario') != 'maintenance':
            result['uinput'] = kernel_input_probe()
        stage = marker['stage']
        if stage == 'desktop':
            Path('/run/farpane-kernel-probe.json').write_text(json.dumps(result))
            Path('/.dockerenv').unlink(missing_ok=True)
            os.execv('/usr/lib/systemd/systemd',
                     ['/sbin/init','--unit=farpane-input-test.target'])
        if stage != 'bootstrap':
            from native_input_vm_service import exercise
            result['service'] = exercise()
            result['scope'] = result['service']['scope']
        result['result'] = 'pass'
    except Exception:
        result['failure'] = traceback.format_exc()
    finally:
        print('FARPANE_INPUT_VM_RESULT=' + json.dumps(result), flush=True)
        os.sync()
        # This is a reboot syscall in the already verified guest kernel. The
        # host launcher has a separate wall-clock limit and owns only QEMU.
        libc = ctypes.CDLL(None, use_errno=True)
        libc.reboot(0x4321fedc)  # LINUX_REBOOT_CMD_POWER_OFF
        raise RuntimeError('Guest poweroff failed')


if __name__ == '__main__':
    main()
