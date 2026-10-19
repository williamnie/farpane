#!/usr/bin/env python3
"""Bounded original RustDesk comparison, only after a user-approved test window.

No service control, injection, grabs, clipboard reads or configuration access.
The installed launcher/library/unit are pinned; arbitrary executable or input
device paths cannot be supplied. Shares the tested nine-key kernel filter.
Unlike the native observer, original RustDesk has no NativeActivity endpoint:
this binds processes and their device, not an authenticated connection ID.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Linux/diagnostics'))
import paste_keys as keys

EXE = Path('/usr/share/rustdesk/rustdesk')
LIB = Path('/usr/share/rustdesk/lib/librustdesk.so')
UNIT = Path('/usr/lib/systemd/system/rustdesk.service')
PINS = {
    EXE: '58ef1e984727d827836c8ad84ad50a4971db4a3cb80ad7a646982594af155c52',
    LIB: 'b7908e555b0ad96f78b6398a470be0f0c9e07f3ccedb8acfb9ee565c63312896',
    UNIT: '383440724510580ee577b8e48b8c51409d59d8faa0747afbd57081d99eb348a2',
}


def fingerprint(path):
    info = path.lstat()
    keys.require(stat.S_ISREG(info.st_mode) and info.st_uid == 0
                 and not info.st_mode & 0o022, 'untrusted_baseline_file')
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def baseline():
    result = {}
    for path, expected in PINS.items():
        before = fingerprint(path)
        with path.open('rb') as stream:
            actual = hashlib.file_digest(stream, 'sha256').hexdigest()
        keys.require(actual == expected and fingerprint(path) == before, 'baseline_mismatch')
        result[path] = before
    return result


def unit(name):
    keys.require(name in ('rustdesk.service', 'farpane.service'), 'unexpected_unit')
    raw = subprocess.check_output(['systemctl', 'show', name,
        '-p', 'MainPID', '-p', 'ActiveState', '-p', 'FragmentPath', '-p', 'DropInPaths'],
        text=True, timeout=2)
    return dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)


def check_units(original, native):
    keys.require(native.get('MainPID') == '0' and native.get('ActiveState') == 'inactive',
                 'farpane_must_be_stopped_in_approved_window')
    keys.require(original.get('FragmentPath') == str(UNIT) and not original.get('DropInPaths')
                 and original.get('ActiveState') == 'active', 'original_unit_changed')
    pid = int(original['MainPID'])
    keys.require(pid > 1, 'original_service_not_running')
    return pid


def process(pid, uid, role):
    keys.require(pid > 1 and role in ('--service', '--server'), 'invalid_process_scope')
    proc = Path('/proc') / str(pid)
    keys.require(proc.stat().st_uid == uid and (proc / 'exe').readlink() == EXE,
                 'process_identity_changed')
    argv = (proc / 'cmdline').read_bytes().split(b'\0')
    keys.require(len(argv) == 3 and argv[1:] == [role.encode(), b'']
                 and argv[0] in (os.fsencode(EXE), b'/usr/bin/rustdesk'), 'process_role_changed')
    info = LIB.stat()
    mapped = False
    for line in (proc / 'maps').read_text().splitlines():
        fields = line.split(maxsplit=5)
        if len(fields) != 6 or fields[5] != str(LIB):
            continue
        major, minor = (int(v, 16) for v in fields[3].split(':'))
        keys.require(int(fields[4]) == info.st_ino
                     and os.makedev(major, minor) == info.st_dev, 'mapped_library_changed')
        mapped = True
    keys.require(mapped, 'original_core_not_mapped')
    return int((proc / 'stat').read_text().rsplit(') ', 1)[1].split()[19])


def capture(args):
    keys.require(os.geteuid() == 0 and args.uid > 0 and args.host_pid > 1
                 and 1 <= args.seconds <= 60, 'invalid_capture_scope')
    keys.require(os.uname().machine == 'x86_64', 'unsupported_architecture')
    pins = baseline()
    service = check_units(unit('rustdesk.service'), unit('farpane.service'))
    roles = ((service, 0, '--service'), (args.host_pid, args.uid, '--server'))
    starts = [process(*r) for r in roles]
    held = []
    reader = None
    try:
        for pid, _, _ in roles:
            held.append(os.pidfd_open(pid))
        poll = select.poll()
        for fd in held:
            poll.register(fd, select.POLLIN)
        keys.require(not poll.poll(0), 'process_exited')
        binding = keys.keyboard_for_service(service, held[0])
        # Device is derived from the pinned service's uinput FD, never by name alone.
        keys.require(starts == [process(*r) for r in roles], 'process_generation_changed')
        reader = keys.open_reader(binding)
        poll.register(reader, select.POLLIN | select.POLLERR | select.POLLHUP)
        started = time.monotonic()
        deadline = started + args.seconds
        frames = keys.Frames()

        def emit(event, **data):
            print(json.dumps({'schema': 1, 'event': event,
                'elapsed_ms': int((time.monotonic() - started) * 1000), **data},
                separators=(',', ':')), flush=True)

        def verify():
            keys.require(all(fingerprint(p) == value for p, value in pins.items()),
                         'baseline_changed')
            keys.require(starts == [process(*r) for r in roles], 'process_generation_changed')
            event = Path(binding['sysfs'])
            keys.require(event.stat().st_ino == binding['sysfs_inode'] and
                (event / 'dev').read_text().strip() == f"{binding['major']}:{binding['minor']}",
                'device_identity_changed')

        verify()
        emit('ready', product='original-rustdesk', core_sha256=PINS[LIB],
             service_pid=service, host_pid=args.host_pid, seconds=args.seconds,
             device=Path(binding['path']).name, allowed_codes=sorted(keys.KEYS),
             initially_down=keys.key_state(reader), kernel_mask_verified=True,
             authenticated_session_verified=False)
        next_units = started
        while time.monotonic() < deadline:
            verify()
            if time.monotonic() >= next_units:
                keys.require(check_units(unit('rustdesk.service'), unit('farpane.service')) == service,
                             'service_generation_changed')
                next_units = time.monotonic() + 1
            ready = poll.poll(max(0, min(100, int((deadline - time.monotonic()) * 1000))))
            for fd, flags in ready:
                keys.require(fd == reader and not flags & (select.POLLERR | select.POLLHUP | select.POLLNVAL),
                             'process_or_device_closed')
                try:
                    data = os.read(reader, keys.EVENT.size * 256)
                except BlockingIOError:
                    continue
                keys.require(bool(data), 'device_closed')
                parsed = frames.feed(data)
                verify()
                for frame in parsed:
                    emit('keys', events=frame)
        emit('ended', reason='time_limit', allowed_events=frames.count,
             incomplete_frame=bool(frames.pending))
    finally:
        if reader is not None:
            os.close(reader)
        for fd in held:
            os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check-baseline', action='store_true')
    mode.add_argument('--approved-test-window', action='store_true')
    parser.add_argument('--uid', type=int)
    parser.add_argument('--host-pid', type=int)
    parser.add_argument('--seconds', type=int, default=30)
    args = parser.parse_args()
    if not args.check_baseline and (args.uid is None or args.host_pid is None):
        parser.error('Capture requires --uid and --host-pid')
    keys.require(1 <= args.seconds <= 60, 'invalid_capture_duration')

    def timeout(_signum, _frame):
        raise TimeoutError('capture_deadline')

    signal.signal(signal.SIGALRM, timeout)
    signal.signal(signal.SIGTERM, timeout)
    signal.alarm(args.seconds + 8)
    try:
        if args.check_baseline:
            baseline()
            print(json.dumps({'baseline_matches': True, 'input_device_opened': False,
                'service_changed': False, 'pins': {str(p): h for p, h in PINS.items()}}))
        else:
            capture(args)
    finally:
        signal.alarm(0)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('{"schema":1,"event":"ended","reason":"interrupted"}', flush=True)
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError, IndexError, subprocess.SubprocessError) as error:
        print(json.dumps({'schema': 1, 'event': 'ended', 'reason': 'validation_or_device_error',
                          'kind': type(error).__name__}), flush=True)
        sys.exit(1)
