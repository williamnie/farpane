#!/usr/bin/env python3
"""Approved, bounded observation of FarPane's own virtual keyboard only.

Never starts/stops a service, injects/grabs keys or reads clipboard/configuration.
Needs an explicit user test window; --approved-test-window is not authorization
by itself. Records only nine modifier/Insert codes, their state and timing.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Linux/diagnostics'))
import paste_keys as keys


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--uid', type=int, required=True)
    parser.add_argument('--release', type=Path, required=True)
    parser.add_argument('--seconds', type=int, default=30)
    parser.add_argument('--approved-test-window', action='store_true', required=True)
    args = parser.parse_args()
    keys.require(os.geteuid() == 0 and args.uid > 0 and 1 <= args.seconds <= 60,
                 'invalid_capture_scope')
    keys.require(os.uname().machine == 'x86_64', 'unsupported_architecture')

    def timeout(_signum, _frame):
        raise TimeoutError('capture_deadline')

    signal.signal(signal.SIGALRM, timeout)
    signal.signal(signal.SIGTERM, timeout)
    signal.alarm(args.seconds + 8)  # Includes preparation, IPC and cleanup.
    observer = module('native_input_observer', ROOT / 'Scripts/linux/observe-native-input.py')
    activity = observer.activity
    core = activity.installed_core(args.release)
    manifest = json.loads((args.release / 'manifest.json').read_text())
    sha = hashlib.file_digest(core.open('rb'), 'sha256').hexdigest()
    entries = [e for e in manifest['files'] if e['path'] == 'libexec/farpane-core']
    keys.require(len(entries) == 1 and entries[0]['sha256'] == sha, 'core_manifest_mismatch')
    service = int(subprocess.check_output(['systemctl', 'show', 'farpane.service',
        '--property=MainPID', '--value'], text=True, timeout=2).strip())
    observed = activity.observe(args.uid, core)
    keys.require(observed['activity']['inbound'] == 1 and
                 observed['activity']['pending_approvals'] == 0, 'need_one_authenticated_session')
    host = observed['pid']
    roles = ((service, 0, '--service'), (host, args.uid, '--server'))
    starts = [observer.identity(*r[:2], core, r[2]) for r in roles]
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
        reader = keys.open_reader(binding)
        poll.register(reader, select.POLLIN | select.POLLERR | select.POLLHUP)
        started = time.monotonic()
        deadline = started + args.seconds
        frames = keys.Frames()

        def emit(event, **data):
            print(json.dumps({'schema': 1, 'event': event,
                              'elapsed_ms': int((time.monotonic() - started) * 1000),
                              **data}, separators=(',', ':')), flush=True)

        def verify():
            activity.installed_core(args.release)
            keys.require(starts == [observer.identity(*r[:2], core, r[2]) for r in roles],
                         'process_generation_changed')
            event = Path(binding['sysfs'])
            keys.require(event.stat().st_ino == binding['sysfs_inode'] and
                         (event / 'dev').read_text().strip() == f"{binding['major']}:{binding['minor']}",
                         'device_identity_changed')

        verify()
        emit('ready', release=args.release.name, core_sha256=sha,
             service_pid=service, host_pid=host, seconds=args.seconds,
             device=Path(binding['path']).name, allowed_codes=sorted(keys.KEYS),
             initially_down=keys.key_state(reader), kernel_mask_verified=True)
        next_activity = started
        while time.monotonic() < deadline:
            verify()
            if time.monotonic() >= next_activity:
                now = activity.observe(args.uid, core)
                keys.require(now['pid'] == host and now['activity']['generation'] == observed['activity']['generation']
                             and now['activity']['inbound'] == 1, 'session_changed')
                next_activity = time.monotonic() + 1
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
        signal.alarm(0)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('{"schema":1,"event":"ended","reason":"interrupted"}', flush=True)
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError, IndexError, subprocess.SubprocessError) as error:
        # No raw exceptions, sysfs paths supplied by peers, input bodies or logs.
        print(json.dumps({'schema': 1, 'event': 'ended', 'reason': 'validation_or_device_error',
                          'kind': type(error).__name__}), flush=True)
        sys.exit(1)
