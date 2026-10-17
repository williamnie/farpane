"""Build pinned non-FFmpeg native dependencies in a fresh, offline container."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import time


def digest(path, algorithm='sha256'):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, algorithm).hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def installed_inventory(root):
    files = {}
    for path in sorted(root.rglob('*')):
        name, mode = path.relative_to(root).as_posix(), path.lstat().st_mode
        if stat.S_ISREG(mode):
            files[name] = {'sha256': digest(path), 'bytes': path.stat().st_size,
                           'executable': bool(mode & 0o111)}
        elif stat.S_ISLNK(mode):
            require(not path.readlink().is_absolute() and
                    path.resolve(strict=True).is_relative_to(root), 'Unsafe installed link')
            files[name] = {'symlink': str(path.readlink())}
        else:
            require(stat.S_ISDIR(mode), 'Unexpected installed file type')
    return files


def main():
    source, output = Path('/inputs/source'), Path('/output')
    require(Path('/.dockerenv').is_file() and os.geteuid() != 0,
            'Run through the unprivileged container wrapper')
    require(not Path('/dev/dri').exists(), 'No GPU access is needed')
    manifest_path = source / 'source-manifest.json'
    require(digest(manifest_path) == sys.argv[1], 'Source manifest SHA-256 mismatch')
    manifest = json.loads(manifest_path.read_text())
    require(manifest.get('schema') == 1 and
            manifest.get('kind') == 'farpane-native-source-snapshot', 'Wrong source snapshot')
    # Verify precisely the source inputs used by this stage before executing
    # recipes. The supplied hash must come from a previously verified archive.
    selected = {name: entry for name, entry in manifest['files'].items()
                if name.startswith('native-dependencies/') or
                name == 'Linux/native-source-pins.json'}
    actual = {}
    paths = list((source / 'native-dependencies').rglob('*'))
    paths.append(source / 'Linux/native-source-pins.json')
    for path in paths:
        name, mode = path.relative_to(source).as_posix(), path.lstat().st_mode
        if stat.S_ISREG(mode):
            actual[name] = {'sha256': digest(path), 'bytes': path.stat().st_size,
                            'executable': bool(mode & 0o111)}
        elif stat.S_ISLNK(mode):
            require(not path.readlink().is_absolute() and
                    path.resolve(strict=True).is_relative_to(source), 'Unsafe source link')
            actual[name] = {'symlink': str(path.readlink())}
        else:
            require(stat.S_ISDIR(mode), 'Unexpected source file type')
    require(actual == selected, 'Native dependency source inventory mismatch')
    dependencies = source / 'native-dependencies'
    pins = json.loads((source / 'Linux/native-source-pins.json').read_text())
    for name, pin in pins['ports'].items():
        files = {p.relative_to(dependencies / 'ports' / name).as_posix(): digest(p)
                 for p in (dependencies / 'ports' / name).rglob('*') if p.is_file()}
        require(files == pin['files'], 'Port recipe mismatch: ' + name)
    for pin in pins['archives']:
        path = dependencies / 'downloads' / pin['filename']
        require(digest(path) == pin['sha256'] and path.stat().st_size == pin['bytes'],
                'Dependency archive mismatch: ' + pin['filename'])
    metadata = dict(line.split('=', 1) for line in
                    (dependencies / 'vcpkg/scripts/vcpkg-tool-metadata.txt').read_text().splitlines()
                    if line.startswith('VCPKG_') and '=' in line)
    tool_hash = digest(Path('/inputs/vcpkg'), 'sha512')
    require(tool_hash == metadata['VCPKG_GLIBC_SHA'], 'Pinned vcpkg tool SHA-512 mismatch')
    tools = json.loads((dependencies / 'vcpkg/scripts/vcpkg-tools.json').read_text())['tools']
    cmake = next(tool for tool in tools if tool['name'] == 'cmake' and
                 tool.get('os') == 'linux' and tool.get('arch') == 'amd64')
    cmake_hash = digest(Path('/inputs/cmake.tar.gz'), 'sha512')
    require(cmake_hash == cmake['sha512'], 'Pinned CMake tool SHA-512 mismatch')
    # A new directory is mandatory. Never repair, clear, or reuse an installed
    # prefix, and never run a vcpkg manifest containing the old FFmpeg recipe.
    workspace = output / 'work'
    workspace.mkdir()
    with tarfile.open('/inputs/cmake.tar.gz') as archive:
        archive.extractall(workspace / 'tools', filter='data')
    cmake_bin = workspace / 'tools' / Path(cmake['executable']).parent
    for name in ('vcpkg', 'ports', 'downloads'):
        shutil.copytree(dependencies / name, workspace / name, symlinks=True)
    shutil.copyfile('/inputs/vcpkg', workspace / 'vcpkg/vcpkg')
    (workspace / 'vcpkg/vcpkg').chmod(0o755)
    triplets = workspace / 'triplets'
    triplets.mkdir()
    shutil.copyfile('/inputs/x64-linux.cmake', triplets / 'x64-linux.cmake')
    (workspace / 'home').mkdir()
    env = dict(os.environ, HOME=str(workspace / 'home'),
               PATH=str(cmake_bin) + ':' + os.environ['PATH'],
               XDG_CACHE_HOME=str(workspace / 'home/.cache'),
               VCPKG_ROOT=str(workspace / 'vcpkg'), VCPKG_DOWNLOADS=str(workspace / 'downloads'),
               VCPKG_BINARY_SOURCES='clear', VCPKG_DISABLE_METRICS='1',
               VCPKG_FORCE_SYSTEM_BINARIES='1', VCPKG_MAX_CONCURRENCY='4',
               CMAKE_BUILD_PARALLEL_LEVEL='4', CXXFLAGS='-include cstdint')
    ports = sorted(pins['ports'])
    require('ffmpeg' not in ports and 'amd-amf' not in ports, 'Unexpected FFmpeg recipe')
    command = [str(workspace / 'vcpkg/vcpkg'), 'install', '--classic', '--disable-metrics',
               '--no-downloads', '--binarysource=clear', '--triplet=x64-linux',
               '--host-triplet=x64-linux', '--overlay-triplets=' + str(triplets),
               '--x-builtin-ports-root=' + str(workspace / 'ports'), *ports]
    (output / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    print('Verified sources and tool; building ' + ', '.join(ports), flush=True)
    began = time.monotonic()
    with (output / 'dependencies.log').open('w') as log:
        result = subprocess.run(command, cwd=workspace, env=env, stdout=log,
                                stderr=subprocess.STDOUT, timeout=5400)
    require(result.returncode == 0, 'Dependency build failed; see dependencies.log')
    prefix = workspace / 'vcpkg/installed/x64-linux'
    libraries = ['aom', 'jpeg', 'turbojpeg', 'mfx', 'opus', 'pkgconf', 'vpx', 'yuv']
    artifacts = {name: digest(prefix / ('lib/lib' + name + '.a')) for name in libraries}
    require(not list(prefix.rglob('libav*.a')), 'FFmpeg must remain outside this stage')
    # The pinned ffnvcodec header-only port also installs debug/pkg-config
    # metadata. It is not a debug library or a second native compilation.
    require(not list((prefix / 'debug').rglob('*.a')), 'Expected release-only native archives')
    probe = output / 'native-dependencies-probe'
    subprocess.run(['c++', '-O2', '-std=c++17', '-I' + str(prefix / 'include'),
                    '/inputs/probe.cpp', '-L' + str(prefix / 'lib'),
                    '-lyuv', '-lturbojpeg', '-ljpeg', '-lopus', '-laom', '-lvpx',
                    '-lmfx', '-ldl', '-lpthread', '-lm', '-o', str(probe)], check=True)
    check = subprocess.run([str(probe)], capture_output=True, text=True, timeout=30, check=True)
    (output / 'probe.log').write_text(check.stdout + check.stderr)
    abi_records = {name: digest(prefix / 'share' / name / 'vcpkg_abi_info.txt') for name in ports}
    installed_manifest = output / 'installed-manifest.json'
    installed_manifest.write_text(json.dumps(installed_inventory(prefix), indent=2) + '\n')
    report = {'result': 'pass', 'source_manifest_sha256': sys.argv[1],
              'installed_manifest_sha256': digest(installed_manifest),
              'verified_source_entries': len(actual), 'vcpkg_tool_sha512': tool_hash,
              'vcpkg_tool_release': metadata['VCPKG_TOOL_RELEASE_TAG'],
              'cmake_version': cmake['version'], 'cmake_archive_sha512': cmake_hash,
              'ports': ports, 'library_sha256': artifacts, 'fresh_abi_sha256': abi_records,
              'elapsed_seconds': round(time.monotonic() - began, 3),
              'network': 'none', 'binary_cache': False, 'installed_prefix_initially_empty': True,
              'release_only': True, 'ffmpeg_built': False, 'full_native_core_build': False,
              'host_modified': False, 'probe': check.stdout.strip()}
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
