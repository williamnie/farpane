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

ROOT = Path(__file__).resolve().parents[2]


def connection_count():
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--viewer', action='store_true', help='Actual GTK Viewer in a private headless Wayland compositor')
    parser.add_argument('--x11', action='store_true', help='Use private Xwayland for the Viewer (requires --viewer)')
    parser.add_argument('--memory-probe', choices=['baseline','cache','trim','arena2','identity','mmap128k','allocations'], default='baseline')
    parser.add_argument('--artifact', type=Path, help='Use a verified native bundle for the private Viewer test')
    parser.add_argument('--shared-runtime-pages', action='store_true',
                        help='Diagnostic only: read-only, byte-identical system libraries/fonts for PSS attribution')
    parser.add_argument('--home-memory', action='store_true', help='Measure idle Home at 3/10/30 seconds, without a Viewer')
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
    with (ROOT / 'Build/Linux/.gpu-test.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before = connection_count()
        if before != 0:
            raise RuntimeError(f'Probe deferred: installed FarPane has {before} video connection(s)')
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
                if connection_count() != 0:
                    raise RuntimeError('New video connection detected; stopping only the synthetic probe')
                samples += 1
                if time.monotonic() - started > (90 if args.viewer else 30):
                    raise RuntimeError('Synthetic GPU test exceeded its runtime budget')
                time.sleep(.2)
            if process.returncode:
                raise RuntimeError(f'GPU probe exited {process.returncode}')
            after = connection_count()
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
                              'before_connections': before, 'after_connections': after,
                              'idle_checks': samples, 'seconds': time.monotonic() - started}))
        finally:
            if process.poll() is None:
                # The random container name was created by this invocation.
                subprocess.run(['docker', 'rm', '-f', name], check=False, timeout=10)
                process.wait(timeout=10)


if __name__ == '__main__':
    main()
