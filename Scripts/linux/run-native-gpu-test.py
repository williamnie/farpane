#!/usr/bin/env python3
"""One bounded render-node probe; abort if installed FarPane becomes active."""
import fcntl
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import uuid
import argparse
import importlib.util
import select
import sys

ROOT = Path(__file__).resolve().parents[2]


def legacy_connection_count():
    # Read-only legacy IPC query. Never read credentials or alter configuration.
    payload = b'{"t":"VideoConnCount","c":null}'
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(1)
        stream.connect('/tmp/FarPane-1000/ipc')
        stream.sendall(bytes([len(payload) << 2]) + payload)

        def read(count):
            data = b''
            while len(data) < count:
                value = stream.recv(count - len(data))
                if not value:
                    raise RuntimeError('Installed FarPane IPC closed')
                data += value
            return data

        header = read(1)
        header += read(header[0] & 3)
        size = int.from_bytes(header, 'little') >> 2
        if size > 1024:
            raise RuntimeError('Unexpected connection count response size')
        value = json.loads(read(size))
        if value.get('t') != 'VideoConnCount' or type(value.get('c')) is not int:
            raise RuntimeError('Cannot establish installed FarPane idle state')
        return value['c']


class ActivityMonitor:
    """One bounded root observer; no repeated core/config-helper processes."""
    def __init__(self, legacy=False):
        self.legacy = legacy
        self.process = None
        self.last = None

    def __enter__(self):
        if not self.legacy:
            if os.getuid() == 0:
                raise RuntimeError('Run the GPU harness as the desktop user, not root')
            release = Path('/opt/farpane/current').resolve(strict=True)
            self.process = subprocess.Popen(
                ['sudo', '-n', '--', sys.executable, '-I', '-B',
                 str(ROOT / 'Scripts/linux/observe-native-activity.py'),
                 '--uid', str(os.getuid()), '--release', str(release), '--watch'],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return self

    def count(self):
        if self.legacy:
            return legacy_connection_count()
        process = self.process
        if process is None or process.poll() is not None:
            raise RuntimeError('Native activity observer unavailable; GPU probe refused')
        process.stdin.write(b'observe\n')
        process.stdin.flush()
        deadline = time.monotonic() + 2
        data = bytearray()
        while b'\n' not in data:
            ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                raise RuntimeError('Native activity observer timed out; GPU probe refused')
            chunk = os.read(process.stdout.fileno(), 4097 - len(data))
            if not chunk or len(data) + len(chunk) > 4096:
                raise RuntimeError('Native activity observer returned invalid data')
            data.extend(chunk)
        value = json.loads(data)
        if (type(value) is not dict or 'error' in value or value.get('schema') != 1
                or value.get('uid') != os.getuid() or type(value.get('busy_count')) is not int
                or value['busy_count'] < 0 or value.get('idle') is not (value['busy_count'] == 0)
                or type(value.get('activity')) is not dict):
            raise RuntimeError('Native activity unavailable; GPU probe refused')
        observed = value['activity'].get('observed_ms')
        if type(observed) is not int or not 0 <= int(time.monotonic() * 1000) - observed <= 3000:
            raise RuntimeError('Native activity became stale; GPU probe refused')
        self.last = value
        return value['busy_count']

    def __exit__(self, *_):
        if self.process is not None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=2)
            finally:
                self.process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--viewer', action='store_true', help='Actual GTK Viewer in a private headless Wayland compositor')
    parser.add_argument('--x11', action='store_true', help='Use private Xwayland for the Viewer (requires --viewer)')
    parser.add_argument('--memory-probe', choices=['baseline','cache','trim','arena2','identity','mmap128k','allocations'], default='baseline')
    parser.add_argument('--artifact', type=Path, help='Use a verified native bundle for the private Viewer test')
    parser.add_argument('--shared-runtime-pages', action='store_true',
                        help='Diagnostic only: read-only, byte-identical system libraries/fonts for PSS attribution')
    parser.add_argument('--home-memory', action='store_true', help='Measure idle Home at 3/10/30 seconds, without a Viewer')
    parser.add_argument('--legacy-host', action='store_true',
                        help='Explicitly use the pre-native Host video-count query; never a fallback')
    args = parser.parse_args()
    if args.x11 and not args.viewer: parser.error('--x11 requires --viewer')
    if args.memory_probe!='baseline' and not args.viewer: parser.error('--memory-probe requires --viewer')
    if args.shared_runtime_pages and (not args.viewer or args.memory_probe not in ('baseline', 'identity', 'mmap128k')):
        parser.error('--shared-runtime-pages requires --viewer and baseline/identity/mmap128k memory probe')
    if args.home_memory and (not args.viewer or args.x11 or args.memory_probe not in ('identity', 'mmap128k', 'allocations')):
        parser.error('--home-memory requires --viewer, private Wayland and identity/mmap128k/allocations')
    if args.memory_probe == 'allocations' and not args.home_memory:
        parser.error('Allocation profiling is limited to --home-memory; diagnostic PSS/CPU are not product budgets')
    artifact = None
    if args.artifact:
        if not args.viewer: parser.error('--artifact requires --viewer')
        artifact = args.artifact.resolve(strict=True)
        if not artifact.is_relative_to(ROOT / 'Build/Linux/artifacts'):
            parser.error('--artifact must be under this checkout Build/Linux/artifacts')
        spec = importlib.util.spec_from_file_location('native_bundle', ROOT / 'Linux/packaging/native_bundle.py')
        bundle = importlib.util.module_from_spec(spec); spec.loader.exec_module(bundle)
        bundle.verify(artifact)
    with (ROOT / 'Build/Linux/.gpu-test.lock').open('a') as lock, ActivityMonitor(args.legacy_host) as monitor:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = monitor.count()
        if before != 0:
            raise RuntimeError(f'Probe deferred: installed FarPane has {before} active connection/task/media owner(s)')
        lockfile = json.loads((ROOT / 'Linux/dependencies.lock.json').read_text())
        image = lockfile['native_display_test' if args.viewer else 'native_builder']['image']
        name = 'farpane-native-gpu-probe-' + uuid.uuid4().hex[:12]
        command = ['docker', 'run', '--rm', '--name', name, '--network', 'none', '--cpus', '1',
                   '--memory', '1g', '--pids-limit', '128', '--user', f'{os.getuid()}:{os.getgid()}',
                   '--group-add', str(Path('/dev/dri/renderD128').stat().st_gid),
                   '--device', '/dev/dri/renderD128:/dev/dri/renderD128:rw', '--cap-drop', 'ALL',
                   '--security-opt', 'no-new-privileges', '--read-only',
                   '--tmpfs', '/tmp:rw,nosuid,nodev,size=64m',
                   '--mount', f'type=bind,src={ROOT}/Build/Linux/bin,dst=/probe,readonly',
                   '-e', 'LIBVA_DRIVER_NAME=radeonsi', '-e', 'MESA_SHADER_CACHE_DISABLE=true',
                   '--entrypoint', '/probe/native-gpu-viewer', image]
        if args.viewer:
            output = '/workspace/Build/Linux/native-viewer-smoke/' + time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
            command = ['docker', 'run', '--rm', '--name', name, '--network', 'none', '--cpus', '2',
                       '--memory', '2g', '--pids-limit', '512',
                       '--device', '/dev/dri/renderD128:/dev/dri/renderD128:rw',
                       '--security-opt', 'no-new-privileges',
                       '--tmpfs', '/opt:rw,exec,mode=755', '--tmpfs', '/run/farpane-native-test:rw,mode=755',
                       '--mount', f'type=bind,src={ROOT},dst=/workspace,readonly',
                       '--mount', f'type=bind,src={ROOT}/Build/Linux,dst=/workspace/Build/Linux',
                       '-e', 'FARPANE_NATIVE_TEST_MODE=' + ('gpu-x11' if args.x11 else 'gpu'), '-e', 'LIBVA_DRIVER_NAME=radeonsi',
                       '-e', 'MESA_SHADER_CACHE_DISABLE=' + ('false' if args.memory_probe=='cache' else 'true'),
                       '-e', 'MESA_SHADER_CACHE_DIR=/run/farpane-native-test/cache/mesa',
                       '-e', 'FARPANE_NATIVE_MEMORY_PROBE=' + args.memory_probe, '--workdir', '/workspace',
                       '--entrypoint', 'python3', image, '/workspace/Linux/tests/native_viewer_smoke.py',
                       output, str(os.getuid()), str(os.getgid())]
            if artifact:
                command[2:2] = ['-e', 'FARPANE_NATIVE_TEST_ARTIFACT=/workspace/' + artifact.relative_to(ROOT).as_posix()]
            if args.home_memory:
                command[2:2] = ['-e', 'FARPANE_NATIVE_TEST_HOME_ONLY=1']
            print('private_viewer_output=' + output, flush=True)
        shared_pages = None
        if args.shared_runtime_pages:
            spec = importlib.util.spec_from_file_location('native_shared_runtime', ROOT / 'Linux/tests/native_shared_runtime.py')
            shared_pages = importlib.util.module_from_spec(spec); spec.loader.exec_module(shared_pages)
            directory = ROOT / 'Build/Linux/native-memory-runtime'
            directory.mkdir(exist_ok=True)
            report = directory / ('shared-pages-' + name + '.json')
            mounts, shared_before = shared_pages.prepare(image, report)
            command[2:2] = mounts
            print('shared_pages_report=' + str(report), flush=True)
        started = time.monotonic()
        process = subprocess.Popen(command)
        samples = 0
        try:
            while process.poll() is None:
                if monitor.count() != 0:
                    raise RuntimeError('Installed FarPane became busy; stopping only the synthetic probe')
                samples += 1
                if time.monotonic() - started > (90 if args.viewer else 30):
                    raise RuntimeError('Synthetic GPU test exceeded its runtime budget')
                time.sleep(.2)
            if process.returncode:
                raise RuntimeError(f'GPU probe exited {process.returncode}')
            after = monitor.count()
            if after != 0:
                raise RuntimeError('Installed FarPane became active at probe completion')
            if shared_pages:
                shared_pages.verify_unchanged(shared_before)
            print(json.dumps({'result': 'pass', 'render_node': 'renderD128',
                              'dimensions': None if args.home_memory else '256x128',
                              'window_dimensions': '1020x720' if args.viewer else None,
                              'fixture': 'idle-home' if args.home_memory else 'static-loopback-desktop' if args.viewer else 'sequential-codec-probe',
                              'memory_probe': args.memory_probe,
                              'shared_runtime_pages': args.shared_runtime_pages,
                              'virtual_output_fps': 12 if args.viewer else None,
                              'codec_probe_fps_cap': None if args.viewer else 12,
                              'guard': 'legacy-video-count' if args.legacy_host else 'native-activity',
                              'last_native_observation': monitor.last,
                              'before_activity_count': before, 'after_activity_count': after,
                              'idle_checks': samples, 'seconds': time.monotonic() - started}))
        finally:
            if process.poll() is None:
                # The random container name was created by this invocation.
                subprocess.run(['docker', 'rm', '-f', name], check=False, timeout=10)
                process.wait(timeout=10)


if __name__ == '__main__':
    main()
