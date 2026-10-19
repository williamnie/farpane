#!/usr/bin/env python3
"""Bounded, read-only triage of the currently installed FarPane input path.

This is NOT a Seq/clipboard/kernel acknowledgement tracer. Only fixed message
categories from *new* existing log records and NativeActivity counts leave this
process. Existing raw log messages are classified in memory and never exported.
No clipboard, input devices, configuration or application widgets are queried.
No services, logging levels or desktop state are changed.
"""
import argparse
import collections
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('native_activity_observer',
    ROOT / 'Scripts/linux/observe-native-activity.py')
activity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activity)

# Accept the source-location prefix emitted by flexi_logger opt_format. Never
# copy the message, source location, peer ID, key, error detail or timestamp.
PREFIX = re.compile(rb'^\[[^\r\n\]]{1,64}\]\s+(TRACE|DEBUG|INFO|WARN|ERROR)\s+'
                    rb'\[([A-Za-z0-9_./-]+\.rs):[0-9]+\]\s+(.*)$')
RULES = (
    ('input_clipboard_set_failed', b'input_service.rs',
     b'set_clipboard_content: failed to set clipboard with owner marker:'),
    ('input_transport_dropped', b'input_retry.rs',
     b'Native input was dropped while its service was unavailable:'),
    ('input_state_query_failed', b'uinput.rs', b'Native input key-state query failed:'),
    ('uinput_sequence_call', b'uinput.rs', b'UInputKeyboard::key_sequence called (len='),
    ('uinput_non_ascii_skipped', b'uinput.rs',
     b'Skipping non-ASCII character in uinput service (no clipboard access)'),
    ('keyboard_device_created', b'uinput.rs', b'UInput keyboard device created successfully'),
    ('keyboard_device_failed', b'uinput.rs', b'Failed to create keyboard '),
    ('keyboard_ipc_closed', b'uinput.rs', b'UInput keyboard ipc connection closed:'),
    ('input_backend_created', b'input_service.rs', b'UInput keyboard created'),
)


def classify(line):
    match = PREFIX.fullmatch(line.rstrip(b'\r\n'))
    if not match:
        return None
    _, source, message = match.groups()
    source = source.rsplit(b'/', 1)[-1]
    for category, expected_source, prefix in RULES:
        if source == expected_source and message.startswith(prefix):
            return category
    return None


class Lines:
    """Drop overlong records entirely, including across read boundaries."""
    def __init__(self):
        self.pending = b''
        self.dropping = False
        self.oversize = 0

    def feed(self, data):
        counts = collections.Counter()
        parts = data.split(b'\n')
        for index, part in enumerate(parts):
            complete = index < len(parts) - 1
            if not self.dropping:
                if len(self.pending) + len(part) > 8192:
                    self.pending = b''
                    self.dropping = True
                    self.oversize += 1
                else:
                    self.pending += part
            if complete:
                if not self.dropping:
                    category = classify(self.pending)
                    if category:
                        counts[category] += 1
                self.pending = b''
                self.dropping = False
        return dict(counts)


def identity(pid, uid, core, role):
    proc = Path('/proc') / str(pid)
    activity.require(proc.stat().st_uid == uid and (proc / 'exe').readlink() == core,
                     'Process identity changed')
    activity.require((proc / 'cmdline').read_bytes().split(b'\0') ==
                     [os.fsencode(core), role.encode(), b''], 'Process role changed')
    return int((proc / 'stat').read_text().rsplit(') ', 1)[1].split()[19])


class LogTail:
    def __init__(self, pid, uid, path):
        self.path, self.uid, self.pid = path, uid, pid
        self.fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        metadata = os.fstat(self.fd)
        activity.require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == uid,
                         'Unexpected log file ownership/type')
        self.key = (metadata.st_dev, metadata.st_ino)
        self.verify()
        # Exclude all pre-existing records, even a partially written last line.
        size = os.lseek(self.fd, 0, os.SEEK_END)
        self.lines = Lines()
        if size and os.pread(self.fd, 1, size - 1) != b'\n':
            self.lines.dropping = True
        self.bytes = 0

    def verify(self):
        metadata = self.path.lstat()
        activity.require(stat.S_ISREG(metadata.st_mode) and
                         (metadata.st_dev, metadata.st_ino) == self.key,
                         'Log rotated or replaced; capture ended')
        attached = False
        for fd in (Path('/proc') / str(self.pid) / 'fd').iterdir():
            try:
                info = fd.stat()
                attached |= (info.st_dev, info.st_ino) == self.key
            except FileNotFoundError:
                continue
        activity.require(attached, 'Log is no longer attached to the verified process')

    def read(self):
        self.verify()
        activity.require(os.fstat(self.fd).st_size >= os.lseek(self.fd, 0, os.SEEK_CUR),
                         'Log truncated; capture ended')
        data = os.read(self.fd, 262144)
        self.bytes += len(data)
        activity.require(self.bytes <= 8 * 1024 * 1024, 'Log capture byte limit exceeded')
        return self.lines.feed(data)

    def close(self):
        os.close(self.fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--uid', type=int, required=True)
    parser.add_argument('--release', type=Path, required=True)
    parser.add_argument('--seconds', type=int, default=300)
    args = parser.parse_args()
    activity.require(os.geteuid() == 0 and args.uid > 0 and 1 <= args.seconds <= 600,
                     'Requires root, desktop UID and a duration of 1..600 seconds')
    core = activity.installed_core(args.release)
    manifest = json.loads((args.release / 'manifest.json').read_text())
    core_sha = hashlib.file_digest(core.open('rb'), 'sha256').hexdigest()
    entries = [entry for entry in manifest['files'] if entry['path'] == 'libexec/farpane-core']
    activity.require(len(entries) == 1, 'Core manifest entry missing or ambiguous')
    expected = entries[0]['sha256']
    activity.require(core_sha == expected, 'Installed core differs from manifest')
    service_pid = int(subprocess.check_output(
        ['systemctl', 'show', 'farpane.service', '--property=MainPID', '--value'],
        text=True, timeout=3).strip())
    observed = activity.observe(args.uid, core)
    host_pid = observed['pid']
    roles = ((service_pid, 0, '--service'), (host_pid, args.uid, '--server'))
    starts = [identity(pid, uid, core, role) for pid, uid, role in roles]
    home = Path(pwd.getpwuid(args.uid).pw_dir)
    logs = [LogTail(service_pid, 0, Path('/root/.local/share/logs/FarPane/service/farpane-core_rCURRENT.log')),
            LogTail(host_pid, args.uid, home / '.local/share/logs/FarPane/server/farpane-core_rCURRENT.log')]
    started = time.monotonic()

    def emit(event, **fields):
        print(json.dumps({'schema': 1, 'event': event,
                          'elapsed_ms': int((time.monotonic() - started) * 1000),
                          **fields}, separators=(',', ':')), flush=True)

    emit('ready', release=args.release.name, core_sha256=core_sha,
         service_pid=service_pid, host_pid=host_pid, process_starts=starts,
         duration_seconds=args.seconds,
         coverage='existing_error_categories_and_activity_only')
    previous = None
    next_activity = next_heartbeat = started
    totals = collections.Counter()
    try:
        while time.monotonic() - started < args.seconds:
            activity.installed_core(args.release)
            activity.require(starts == [identity(pid, uid, core, role) for pid, uid, role in roles],
                             'Process generation changed')
            for role, log in zip(('service', 'host'), logs):
                counts = log.read()
                if counts:
                    totals.update(counts)
                    emit('log_categories', role=role, counts=counts)
            now = time.monotonic()
            if now >= next_activity:
                current = activity.observe(args.uid, core)
                activity.require(current['pid'] == host_pid and
                                 current['activity']['generation'] == observed['activity']['generation'],
                                 'Host activity generation changed')
                counters = {name: current['activity'][name] for name in activity.COUNTS}
                if counters != previous:
                    emit('activity', **counters)
                    previous = counters
                next_activity = now + 3
            if now >= next_heartbeat:
                emit('heartbeat')
                next_heartbeat = now + 20
            time.sleep(min(0.5, max(0, started + args.seconds - time.monotonic())))
        emit('ended', reason='time_limit', totals=dict(totals),
             dropped_oversize_records=sum(log.lines.oversize for log in logs))
    finally:
        for log in logs:
            log.close()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('{"schema":1,"event":"ended","reason":"interrupted"}', flush=True)
    except (OSError, ValueError, TypeError, KeyError, IndexError, subprocess.SubprocessError) as error:
        # Never print arbitrary exception/log/IPC content.
        print(json.dumps({'schema': 1, 'event': 'ended', 'reason': 'capture_unavailable',
                          'kind': type(error).__name__}), flush=True)
        sys.exit(1)
