"""Read-only input-device binding and per-reader filtering; never inject/grab.

Linux x86-64 only. EVIOCSMASK changes this reader's queue, not device state.
UI_GET_SYSNAME is used on a temporary duplicate of the service's uinput FD;
closing it immediately avoids keeping the virtual device alive during capture.
"""
import ctypes
import fcntl
import os
from pathlib import Path
import re
import stat
import struct

KEYS = {29: 'left_control', 97: 'right_control', 42: 'left_shift',
        54: 'right_shift', 56: 'left_alt', 100: 'right_alt',
        125: 'left_meta', 126: 'right_meta', 110: 'insert'}
EVENT = struct.Struct('llHHi')
NAME = 'RustDesk UInput Keyboard'


def require(ok, code):
    if not ok:
        raise ValueError(code)


def ioctl_code(direction, kind, number, size):
    return (direction << 30) | (size << 16) | (ord(kind) << 8) | number


def read_ioctl(fd, kind, number, size):
    data = bytearray(size)
    fcntl.ioctl(fd, ioctl_code(2, kind, number, size), data, True)
    return bytes(data)


def sysname(fd):
    name = read_ioctl(fd, 'U', 44, 128).split(b'\0', 1)[0].decode('ascii')
    require(re.fullmatch(r'input[0-9]+', name), 'unexpected_uinput_sysname')
    return name


def duplicate_fd(pidfd, target_fd):
    require(os.uname().machine == 'x86_64', 'unsupported_architecture')
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    descriptor = libc.syscall(438, pidfd, target_fd, 0)  # __NR_pidfd_getfd
    if descriptor < 0:
        raise OSError(ctypes.get_errno(), 'pidfd_getfd_failed')
    os.set_inheritable(descriptor, False)
    return descriptor


def keyboard_for_service(pid, pidfd):
    """Name alone is insufficient: derive the sysfs device from its owner's FD."""
    found = set()
    descriptors = list((Path('/proc') / str(pid) / 'fd').iterdir())
    require(len(descriptors) <= 4096, 'descriptor_limit')
    for path in descriptors:
        # Enumerating /proc/self/fd also lists the short-lived directory FD;
        # ordinary unrelated descriptors may disappear in a live service.
        try:
            target = str(path.readlink())
        except FileNotFoundError:
            continue
        if target not in ('/dev/uinput', '/dev/input/uinput'):
            continue
        try:
            descriptor = duplicate_fd(pidfd, int(path.name))
            try:
                metadata = os.fstat(descriptor)
                require(stat.S_ISCHR(metadata.st_mode) and
                        (os.major(metadata.st_rdev), os.minor(metadata.st_rdev)) == (10, 223),
                        'unexpected_uinput_device')
                name = sysname(descriptor)
            finally:
                os.close(descriptor)
            device = Path('/sys/devices/virtual/input') / name
            if (device / 'name').read_text().strip() == NAME:
                found.add(device)
        except FileNotFoundError:
            raise ValueError('device_changed') from None
    require(len(found) == 1, 'keyboard_owner_unknown_or_ambiguous')
    device = found.pop()
    events = [p for p in device.iterdir() if re.fullmatch(r'event[0-9]+', p.name)]
    require(len(events) == 1, 'evdev_unknown_or_ambiguous')
    event = events[0]
    major, minor = map(int, (event / 'dev').read_text().strip().split(':'))
    require(major == 13, 'unexpected_evdev_major')
    return {'path': str(Path('/dev/input') / event.name), 'sysfs': str(event),
            'major': major, 'minor': minor, 'sysfs_inode': event.stat().st_ino}


def bitmap(codes):
    data = bytearray(128)
    for code in codes:
        data[code // 8] |= 1 << (code % 8)
    return bytes(data)


def install_masks(fd):
    # type 0 is the event-type mask; for EV_KEY, expose only nine codes.
    # No MSC_SCAN, letters, pointer coordinates or text reach this reader.
    for event_type, codes in ((0, (0, 1)), (1, KEYS)):
        expected = bitmap(codes)
        buffer = ctypes.create_string_buffer(expected, len(expected))
        arg = struct.pack('IIQ', event_type, len(expected), ctypes.addressof(buffer))
        fcntl.ioctl(fd, ioctl_code(1, 'E', 0x93, 16), arg)  # EVIOCSMASK
        ctypes.memset(ctypes.addressof(buffer), 0, len(expected))
        fcntl.ioctl(fd, ioctl_code(2, 'E', 0x92, 16), arg)  # EVIOCGMASK
        require(buffer.raw == expected, 'event_mask_not_applied')


def open_reader(binding):
    path = Path(binding['path'])
    require(path.parent == Path('/dev/input') and re.fullmatch(r'event[0-9]+', path.name),
            'unexpected_event_path')
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(fd)
        require(stat.S_ISCHR(metadata.st_mode) and metadata.st_uid == 0 and
                metadata.st_rdev == os.makedev(binding['major'], binding['minor']),
                'unexpected_event_identity')
        name = read_ioctl(fd, 'E', 0x06, 128).split(b'\0', 1)[0].decode('ascii')
        require(name == NAME, 'unexpected_event_name')
        install_masks(fd)
        # Exclude anything queued between open() and setting the masks.
        for _ in range(16):
            try:
                require(bool(os.read(fd, EVENT.size * 256)), 'device_closed')
            except BlockingIOError:
                return fd
        raise ValueError('initial_queue_not_quiet')
    except BaseException:
        os.close(fd)
        raise


def key_state(fd):
    state = read_ioctl(fd, 'E', 0x18, 128)
    return [KEYS[k] for k in KEYS if state[k // 8] & (1 << (k % 8))]


class Frames:
    """Defence in depth: never return other keycodes, even without kernel masks."""
    def __init__(self):
        self.pending = []
        self.origin = None
        self.count = 0

    def feed(self, data):
        require(len(data) <= EVENT.size * 256 and len(data) % EVENT.size == 0,
                'invalid_event_framing')
        output = []
        for sec, usec, kind, code, value in EVENT.iter_unpack(data):
            if kind == 0 and code == 3:  # SYN_DROPPED: no inference across missing input.
                self.pending.clear()
                raise ValueError('kernel_events_lost')
            if kind == 1 and code in KEYS:
                require(sec >= 0 and 0 <= usec < 1000000 and value in (0, 1, 2),
                        'invalid_allowed_event')
                timestamp = sec * 1000000 + usec
                if self.origin is None:
                    self.origin = timestamp
                self.count += 1
                require(self.count <= 256 and len(self.pending) < 32, 'event_limit')
                self.pending.append({'key': KEYS[code], 'code': code,
                                     'state': ('up', 'down', 'repeat')[value],
                                     'relative_us': timestamp - self.origin})
            elif kind == 0 and code == 0:
                if self.pending:
                    output.append(self.pending)
                    self.pending = []
        return output
