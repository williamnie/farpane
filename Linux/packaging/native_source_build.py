"""Build the complete native application from a verified source snapshot."""
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
import zipfile


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def inventory(root, exclude=()):
    files = {}
    for path in sorted(root.rglob('*')):
        name, mode = path.relative_to(root).as_posix(), path.lstat().st_mode
        if name in exclude:
            continue
        if stat.S_ISREG(mode):
            files[name] = {'sha256': digest(path), 'bytes': path.stat().st_size,
                           'executable': bool(mode & 0o111)}
        elif stat.S_ISLNK(mode):
            require(not path.readlink().is_absolute() and
                    path.resolve(strict=True).is_relative_to(root), 'Unsafe input link: ' + name)
            files[name] = {'symlink': str(path.readlink())}
        else:
            require(stat.S_ISDIR(mode), 'Unexpected input file: ' + name)
    return files


def main():
    source, dependencies = Path('/inputs/source'), Path('/inputs/dependencies')
    output, workspace = Path('/output'), Path('/workspace')
    verify_only = sys.argv[3:] == ['--verify']
    require(not sys.argv[3:] or verify_only, 'Unknown verification mode')
    require(Path('/.dockerenv').is_file() and os.geteuid() != 0, 'Use the isolated wrapper')
    require(not Path('/dev/dri').exists(), 'This build does not need GPU access')
    require(not (output / 'result.json').exists(), 'Preserving the completed build result')
    if not verify_only:
        require(not any(workspace.iterdir()), 'Refusing to reuse a build workspace')
        require(not (output / 'cargo-home').exists(), 'Cargo home must initially be empty')
    require(digest(source / 'source-manifest.json') == sys.argv[1], 'Source manifest mismatch')
    manifest = json.loads((source / 'source-manifest.json').read_text())
    require(manifest['schema'] == 1 and manifest['kind'] == 'farpane-native-source-snapshot',
            'Not a native source snapshot')
    print('Verifying every source snapshot entry', flush=True)
    require(inventory(source, ('source-manifest.json',)) == manifest['files'],
            'Source snapshot inventory mismatch')
    require(digest(dependencies / 'installed-manifest.json') == sys.argv[2],
            'Native dependency inventory hash mismatch')
    dependency_inventory = json.loads((dependencies / 'installed-manifest.json').read_text())
    dependency_prefix = dependencies / 'work/vcpkg/installed/x64-linux'
    require(inventory(dependency_prefix) == dependency_inventory, 'Native prefix inventory mismatch')
    dependency_result = json.loads((dependencies / 'result.json').read_text())
    require(dependency_result['result'] == 'pass' and
            dependency_result['source_manifest_sha256'] == sys.argv[1] and
            dependency_result['installed_prefix_initially_empty'] is True and
            dependency_result['binary_cache'] is False and
            dependency_result['ffmpeg_built'] is False, 'Wrong native dependency build')
    build = workspace / 'Build/Linux'
    prefix = build / 'vcpkg/installed/x64-linux'
    lock = json.loads((source / 'Linux/dependencies.lock.json').read_text())
    if not verify_only:
        print('Copying verified sources and freshly built non-FFmpeg prefix', flush=True)
        shutil.copytree(source, workspace, symlinks=True, dirs_exist_ok=True)
        require(not (build / 'vcpkg').exists(), 'Source snapshot includes an installed prefix')
        require(not (build / 'source-target').exists(), 'Compiler target must initially be empty')
        shutil.copytree(dependency_prefix, prefix, symlinks=True)
        downloads = build / 'downloads'
        amf = lock['amf_headers']
        amf_archive = downloads / ('AMF-v' + amf['version'] + '.tar.gz')
        require(digest(amf_archive) == amf['sha256'], 'AMF archive mismatch')
        amf_root = 'AMF-' + amf['version'] + '/amf/public/include/'
        with tarfile.open(amf_archive) as archive:
            archive.extractall(build / 'src', members=[member for member in archive
                               if member.name.startswith(amf_root)], filter='data')
        shutil.copytree(build / 'src' / amf_root, prefix / 'include/AMF')
        meson = lock['meson']
        wheel = downloads / meson['filename']
        require(digest(wheel) == meson['sha256'], 'Meson wheel mismatch')
        with zipfile.ZipFile(wheel) as archive:
            archive.extractall(build / 'tools' / ('meson-' + meson['version']))
        for name in ('home', 'cargo-home'):
            (output / name).mkdir()
    env = dict(os.environ, HOME=str(output / 'home'), CARGO_HOME=str(output / 'cargo-home'),
               CARGO_TARGET_DIR=str(build / 'source-target'), CARGO_BUILD_JOBS='4',
               VCPKG_ROOT=str(build / 'vcpkg'), CXXFLAGS='-include cstdint',
               PATH='/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin')
    compiler = subprocess.check_output(['rustc', '--version'], env=env, text=True).strip()
    require(compiler.startswith('rustc ' + lock['builder']['rust'] + ' '), 'Wrong Rust SDK')
    sdk_record = {'rustc_sha256': digest(Path('/toolchain/bin/rustc')),
                  'cargo_sha256': digest(Path('/toolchain/bin/cargo')),
                  'compiler_verbose': subprocess.check_output(['rustc', '-vV'], env=env, text=True),
                  'cargo_version': subprocess.check_output(['cargo', '--version'], env=env, text=True).strip()}
    sdk_receipt = Path('/toolchain/toolchain-receipt.json')
    sdk_record['receipt_sha256'] = digest(sdk_receipt) if sdk_receipt.is_file() else None
    stages = {}

    def run(name, command, timeout=3600):
        print('Building ' + name, flush=True)
        began = time.monotonic()
        (output / 'active-stage.json').write_text(json.dumps({'stage': name, 'command': command}) + '\n')
        with (output / (name + '.log')).open('w') as log:
            result = subprocess.run(command, cwd=workspace, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=timeout)
        stages[name] = {'returncode': result.returncode, 'seconds': round(time.monotonic() - began, 3),
                        'command': command, 'log_sha256': digest(output / (name + '.log'))}
        (output / 'stages.json').write_text(json.dumps(stages, indent=2) + '\n')
        require(result.returncode == 0, name + ' failed; see ' + name + '.log')

    commands = {
        'ffmpeg': ['bash', 'Scripts/linux/build-ffmpeg.sh'],
        'drmtap': ['bash', 'Scripts/linux/build-drmtap.sh'],
        'core-release': ['bash', 'Scripts/linux/build-native-core.sh', 'release'],
        'gui-release': ['cargo', 'build', '--offline', '--locked', '--release',
                        '--manifest-path', 'Build/Linux/gui/Cargo.toml'],
    }
    if verify_only:
        print('Verifying already completed build stages; no compilation will run', flush=True)
        stages = json.loads((output / 'stages.json').read_text())
        require(stages.keys() == commands.keys(), 'Incomplete build stage set')
        for name, command in commands.items():
            stage = stages[name]
            require(stage['returncode'] == 0 and stage['command'] == command and
                    stage['log_sha256'] == digest(output / (name + '.log')),
                    'Incomplete or changed build stage: ' + name)
        # The upstream build script regenerates this one captured source file.
        # Every other original input must still match the verified snapshot.
        for name, entry in manifest['files'].items():
            if name == 'Build/Linux/src/rustdesk/src/version.rs':
                continue
            path = workspace / name
            if 'sha256' in entry:
                require(path.is_file() and not path.is_symlink() and digest(path) == entry['sha256'],
                        'Changed build source: ' + name)
            else:
                require(path.is_symlink() and str(path.readlink()) == entry['symlink'],
                        'Changed source link: ' + name)
    else:
        for name, command in commands.items():
            run(name, command)
    binaries = {'native-core': build / 'source-target/release/farpane-core',
                'native-gui': build / 'source-target/release/farpane'}
    components = {}
    for name, binary in binaries.items():
        info = subprocess.run([str(binary), '--build-info'], cwd=workspace, env=env,
                              capture_output=True, text=True, timeout=15, check=True)
        component = json.loads(info.stdout)
        require(component['component'] == name and component['runtime_ready'] is False,
                'Wrong component capabilities')
        components[name] = component
        (output / (name + '-build-info.json')).write_text(json.dumps(component, indent=2) + '\n')
        dynamic = subprocess.check_output(['readelf', '-d', str(binary)], text=True)
        (output / (name + '-dynamic.txt')).write_text(dynamic)
        require(not any(item in dynamic.lower() for item in ('libflutter', 'libsciter', 'libgtk-3',
                                                             'libavcodec.so', 'libavutil.so')),
                'Unexpected legacy/dynamic media dependency')
        linked = subprocess.check_output(['ldd', str(binary)], text=True)
        require('not found' not in linked, 'Unresolved application library')
        (output / (name + '-ldd.txt')).write_text(linked)
    require(components['native-core']['gpu_host_compiled'] is True and
            components['native-core']['legacy_ui'] is False, 'Native GPU core missing')
    require(components['native-core']['protocol'] == components['native-gui']['protocol'],
            'Core/GUI protocol mismatch')
    require(not (output / 'cargo-home/registry').exists() and
            not (output / 'cargo-home/git').exists(), 'Cargo downloaded outside vendor')
    ffmpeg = {name: digest(prefix / ('lib/lib' + name + '.a'))
              for name in ('avcodec', 'avutil', 'avformat', 'avfilter')}
    drmtap = [path for path in (build / 'drmtap-build').glob('libdrmtap.so.0.*')
              if path.is_file() and not path.is_symlink()]
    require(len(drmtap) == 1, 'Expected one private drmtap library')
    report = {'result': 'pass', 'source_manifest_sha256': sys.argv[1],
              'native_dependency_manifest_sha256': sys.argv[2],
              'source_entries': len(manifest['files']), 'compiler': compiler, 'rust_sdk': sdk_record,
              'binaries': {name: digest(path) for name, path in binaries.items()},
              'ffmpeg_static_sha256': ffmpeg, 'drmtap_sha256': digest(drmtap[0]),
              'stages': stages, 'network': 'none', 'cargo_cache_initially_empty': True,
              'compiler_target_initially_empty': True, 'nonffmpeg_dependencies_freshly_built': True,
              'full_native_media_core_gui_build': True, 'runtime_integration_verified': False,
              'verification_only_after_completed_stages': verify_only,
              'toolchain_built_from_source': False, 'complete_license_source_audit': False,
              'installed_application_modified': False}
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    main()
