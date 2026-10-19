"""Only invoked by PID 1 after the private KVM guest's isolation checks."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import select
import struct
import time


def exercise():
    assert os.getpid() == 1 and os.geteuid() == 0
    assert json.loads(Path('/.farpane-input-vm').read_text())['isolation'] == 'guest-kernel-uinput'
    assert 'farpane.input-vm=1' in Path('/proc/cmdline').read_text().split()
    spec = importlib.util.spec_from_file_location('paste_keys', Path(__file__).with_name('paste_keys.py'))
    keys = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(keys)
    descriptor = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    pidfd = None
    reader = None
    unfiltered = None
    try:
        fcntl.ioctl(descriptor, 0x40045564, 1)
        for code in [30, 31, *keys.KEYS]:
            fcntl.ioctl(descriptor, 0x40045565, code)
        setup = struct.pack('HHHH80sI', 3, 0x1234, 1, 1, keys.NAME.encode(), 0)
        fcntl.ioctl(descriptor, 0x405c5503, setup)
        fcntl.ioctl(descriptor, 0x5501)
        name = keys.sysname(descriptor)
        deadline = time.monotonic() + 3
        event = None
        while time.monotonic() < deadline:
            events = list((Path('/sys/devices/virtual/input') / name).glob('event*'))
            if events:
                event = events[0]
                break
            time.sleep(.01)
        assert event is not None
        target = Path('/dev/input') / event.name
        if not target.exists():
            major, minor = map(int, (event / 'dev').read_text().split(':'))
            target.parent.mkdir(exist_ok=True)
            os.mknod(target, 0o20600, os.makedev(major, minor))
        pidfd = os.pidfd_open(os.getpid())
        binding = keys.keyboard_for_service(os.getpid(), pidfd)
        assert binding['path'] == str(target)
        reader = keys.open_reader(binding)
        unfiltered = os.open(target, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        expected = [(30, 1), (30, 0), (42, 1), (110, 1), (110, 0), (42, 0), (31, 1), (31, 0)]
        payload = b''.join(keys.EVENT.pack(0, 0, 1, k, v) + keys.EVENT.pack(0, 0, 0, 0, 0)
                           for k, v in expected)
        assert os.write(descriptor, payload) == len(payload)
        seen = {reader: [], unfiltered: []}
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and (len(seen[unfiltered]) < len(expected) or len(seen[reader]) < 4):
            ready, _, _ = select.select(list(seen), [], [], .1)
            for fd in ready:
                for _, _, kind, code, value in keys.EVENT.iter_unpack(os.read(fd, keys.EVENT.size * 256)):
                    if kind == 1:
                        seen[fd].append((code, value))
        assert seen[unfiltered] == expected, seen[unfiltered]
        assert seen[reader] == [(42, 1), (110, 1), (110, 0), (42, 0)], seen[reader]
        assert keys.key_state(reader) == []
        return {'result': 'pass', 'owner_bound_by_pidfd': True, 'kernel_key_filter_verified': True,
                'other_reader_unaffected': True, 'normal_keys_delivered_to_observer': 0,
                'allowed_keys': seen[reader], 'host_input_accessed': False}
    finally:
        for fd in (reader, unfiltered, pidfd, descriptor):
            if fd is not None:
                os.close(fd)
