#!/usr/bin/env python3
"""Read native Host activity without opening configuration or using control commands.

The installed Host accepts two read-only observations from kernel-identified
root. This helper sends only NativeActivity. Unknown/stale identity or activity
is an error, never an idle result. stdout contains no credentials or peer IDs.
"""
import argparse
import json
import os
from pathlib import Path
import select
import socket
import stat
import struct
import sys
import time

SO_PEERPIDFD = 77  # Linux 6.5+, no numeric-PID fallback.
FIELDS = {'schema', 'process_start', 'generation', 'observed_ms', 'inbound',
          'pending_approvals', 'file_jobs', 'media_owners'}
COUNTS = ('inbound', 'pending_approvals', 'file_jobs', 'media_owners')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def trusted_core(core):
    require(core.is_absolute(), 'Core path must be absolute')
    for path in (*reversed(core.parents), core):
        metadata = path.lstat()
        require(metadata.st_uid == 0 and not metadata.st_mode & 0o022,
                'Core must have root-owned, non-writable ancestors')
        require(not stat.S_ISLNK(metadata.st_mode), 'Core path must not contain symlinks')
        require(stat.S_ISREG(metadata.st_mode) if path == core else stat.S_ISDIR(metadata.st_mode),
                'Unexpected core path type')


def installed_core(release):
    require(release.parent == Path('/opt/farpane/releases'), 'Unexpected release directory')
    core = release / 'libexec/farpane-core'
    trusted_core(core)
    current = Path('/opt/farpane/current')
    require(current.lstat().st_uid == 0 and current.is_symlink(), 'Unsafe current release link')
    require(current.resolve(strict=True) == release, 'Installed release changed')
    return core


def validate_activity(value, process_start, now_ms):
    require(type(value) is dict and set(value) == FIELDS, 'Unknown activity schema')
    require(all(type(v) is int and 0 <= v <= (1 << 64) - 1 for v in value.values()),
            'Invalid activity field')
    require(value['schema'] == 1 and value['generation'] > 0 and
            value['process_start'] == process_start and process_start > 0,
            'Activity owner or generation mismatch')
    require(0 <= now_ms - value['observed_ms'] <= 3000, 'Stale or future activity')
    require(all(value[k] <= (1 << 32) - 1 for k in COUNTS), 'Invalid activity count')
    return sum(value[k] for k in COUNTS)


def read_frame(connection, deadline):
    def exact(size):
        result = bytearray()
        while len(result) < size:
            remaining = deadline - time.monotonic()
            require(remaining > 0, 'Observation timed out')
            connection.settimeout(remaining)
            chunk = connection.recv(size - len(result))
            require(bool(chunk), 'Observation connection closed')
            result.extend(chunk)
        return bytes(result)
    header = exact(1)
    header += exact(header[0] & 3)
    size = int.from_bytes(header, 'little') >> 2
    require(0 < size <= 4096, 'Observation response exceeds limit')
    try:
        value = json.loads(exact(size))
    except (ValueError, UnicodeError):
        raise ValueError('Invalid observation message') from None
    require(type(value) is dict and set(value) == {'t', 'c'} and
            value['t'] == 'NativeActivity', 'Unexpected observation response')
    return value['c']


def observe(uid, core, endpoint=None):
    require(os.geteuid() == 0 and uid > 0, 'Observation requires root and a desktop UID')
    trusted_core(core)
    deadline = time.monotonic() + 1
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC) as connection:
        connection.settimeout(1)
        connection.connect(str(endpoint or Path(f'/tmp/FarPane-{uid}/ipc')))
        pid, peer_uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        require(pid > 0 and peer_uid == uid, 'Observation peer UID mismatch')
        pidfd = connection.getsockopt(socket.SOL_SOCKET, SO_PEERPIDFD)
        try:
            os.set_inheritable(pidfd, False)
            poller = select.poll()
            poller.register(pidfd, select.POLLIN)
            require(not poller.poll(0), 'Observation peer exited')
            proc = Path('/proc') / str(pid)
            require(proc.stat().st_uid == uid and (proc / 'exe').readlink() == core,
                    'Observation executable mismatch')
            args = (proc / 'cmdline').read_bytes().split(b'\0')
            require(len(args) == 3 and args[1:] == [b'--server', b''], 'Observation role mismatch')
            process_start = int((proc / 'stat').read_text().rsplit(') ', 1)[1].split()[19])
            payload = b'{"t":"NativeActivity","c":null}'
            connection.sendall(bytes([len(payload) << 2]) + payload)
            activity = read_frame(connection, deadline)
            busy = validate_activity(activity, process_start, int(time.monotonic() * 1000))
            require(not poller.poll(0), 'Observation peer exited')
            return {'schema': 1, 'uid': uid, 'pid': pid, 'activity': activity,
                    'busy_count': busy, 'idle': busy == 0}
        finally:
            os.close(pidfd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--uid', type=int, required=True)
    parser.add_argument('--release', type=Path, required=True)
    parser.add_argument('--watch', action='store_true', help='Bounded request/response mode on stdin/stdout')
    args = parser.parse_args()
    require(os.geteuid() == 0 and args.uid > 0, 'Observation requires root and a desktop UID')
    core = installed_core(args.release)
    # Parent EOF, malformed input, an observation failure or the absolute
    # deadline ends this process. It never becomes a background monitor.
    deadline = time.monotonic() + 120
    for _ in range(1000 if args.watch else 1):
        if args.watch:
            remaining = deadline - time.monotonic()
            require(remaining > 0, 'Observation helper lifetime exceeded')
            ready, _, _ = select.select([sys.stdin], [], [], remaining)
            require(bool(ready) and time.monotonic() < deadline, 'Observation helper lifetime exceeded')
            # The parent writes one eight-byte request atomically to a pipe.
            # Never block in readline after receiving only a partial request.
            request = os.read(sys.stdin.fileno(), 9)
            if not request:
                return
            require(request == b'observe\n', 'Unexpected observation request')
        installed_core(args.release)
        result = observe(args.uid, core)
        installed_core(args.release)
        require(time.monotonic() < deadline, 'Observation helper lifetime exceeded')
        print(json.dumps(result, separators=(',', ':')), flush=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, IndexError) as error:
        # Do not echo remote message bodies or arbitrary exception details.
        print(json.dumps({'error': 'Native activity unavailable', 'kind': type(error).__name__}), flush=True)
        sys.exit(1)
