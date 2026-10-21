#!/usr/bin/env python3
"""Create a verified native development bundle under Build; never install/start it."""
import argparse
import gzip
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'Build/Linux'
sys.path.insert(0, str(ROOT / 'Linux/packaging'))
import native_notice_delivery
import native_privacy
spec = importlib.util.spec_from_file_location('native_bundle', ROOT / 'Linux/packaging/native_bundle.py')
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)
receipt_spec = importlib.util.spec_from_file_location('native_receipt', ROOT / 'Linux/packaging/native_receipt.py')
receipt_module = importlib.util.module_from_spec(receipt_spec)
receipt_spec.loader.exec_module(receipt_module)
source_spec = importlib.util.spec_from_file_location('native_package_source', ROOT / 'Linux/packaging/native_package_source.py')
source_module = importlib.util.module_from_spec(source_spec)
source_spec.loader.exec_module(source_module)


def elf_report(path, core=False):
    header = subprocess.check_output(['readelf', '-h', str(path)], text=True)
    if 'ELF64' not in header or 'Advanced Micro Devices X86-64' not in header:
        raise ValueError('Expected x86_64 ELF: ' + str(path))
    dynamic = subprocess.check_output(['readelf', '-d', str(path)], text=True)
    needed = re.findall(r'Shared library: \[([^\]]+)\]', dynamic)
    forbidden = ['libflutter', 'libapp.so', 'libsciter', 'libgtk-3', 'libgdk-3', 'libappindicator',
                 'libavcodec', 'libavutil', 'libavfilter', 'libavformat', 'libswscale', 'libswresample']
    if core:
        forbidden += ['libgtk-4', 'libadwaita']
    if any(name.startswith(tuple(forbidden)) for name in needed):
        raise ValueError('Unexpected legacy UI or dynamic FFmpeg dependency: ' + str(path))
    if re.search(r'\((?:RPATH|RUNPATH)\)', dynamic):
        raise ValueError('Build/runtime search path remains in bundle: ' + str(path))
    versions = subprocess.check_output(['readelf', '--version-info', str(path)], text=True)
    return {'needed': needed, 'symbol_versions': sorted(set(re.findall(r'Name: ([A-Za-z0-9_.]+)', versions))),
            'sha256': bundle.digest(path)}


def copy(source, staged, relative, executable=False):
    if source.is_symlink() or not source.is_file():
        raise ValueError('Expected canonical regular source: ' + str(source))
    path = staged / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, path)
    path.chmod(0o755 if executable else 0o644)
    return path


def package(source_build=None, version=None):
    if version is not None and not re.fullmatch(r'[0-9][0-9A-Za-z.+-]{0,47}', version):
        raise ValueError('Invalid visible product version')
    lock = json.loads((ROOT / 'Linux/dependencies.lock.json').read_text())
    if source_build:
        receipt, inputs, source_proof = source_module.load(source_build, receipt_module.sources())
    else:
        receipt = receipt_module.verify(BUILD / 'native-build.json')
        inputs = {'farpane': BUILD / 'native-target/release/farpane',
                  'libexec/farpane-core': BUILD / 'target/release/farpane-core',
                  'lib/libdrmtap.so.' + lock['libdrmtap']['version']:
                      BUILD / 'drmtap-build' / ('libdrmtap.so.' + lock['libdrmtap']['version'])}
        source_proof = None
    source_origin = source_module.identity(ROOT)
    origin_hashes = {name: bundle.digest(path) for name, path in inputs.items()}
    destination = BUILD / 'artifacts'
    if destination.is_symlink():
        raise ValueError('Artifact directory must not be a symlink')
    destination.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination, prefix='.native-package-') as temporary:
        staged = Path(temporary) / 'bundle'
        staged.mkdir(mode=0o755)
        binaries = {}
        for name, source in inputs.items():
            path = copy(source, staged, name, executable=True)
            # Cargo's rpath points into the build toolchain. Removing it from
            # the artifact copy must not modify the recorded build binary.
            subprocess.run(['patchelf', '--remove-rpath', str(path)], check=True)
            binaries[name] = elf_report(path, core=name == 'libexec/farpane-core')
        (staged / 'lib/libdrmtap.so.0').symlink_to('libdrmtap.so.' + lock['libdrmtap']['version'])
        for source, relative in [
            ('Linux/packaging/org.farpane.FarPane.desktop.in', 'share/applications/org.farpane.FarPane.desktop'),
            ('Linux/packaging/org.farpane.FarPane.service.in', 'share/dbus-1/services/org.farpane.FarPane.service'),
            ('Linux/packaging/farpane-native.service.in', 'systemd/farpane.service'),
            ('Linux/gui/resources/org.farpane.FarPane.svg', 'share/icons/hicolor/scalable/apps/org.farpane.FarPane.svg'),
            ('Linux/gui/resources/org.farpane.FarPane.png', 'share/icons/hicolor/1024x1024/apps/org.farpane.FarPane.png'),
            ('Linux/dependencies.lock.json', 'dependencies.lock.json'), ('LICENSE', 'licenses/FarPane.txt'),
            ('THIRD_PARTY_NOTICES.md', 'licenses/THIRD_PARTY_NOTICES.md'),
        ]:
            copy(ROOT / source, staged, relative)
        prepared = Path(source_build).resolve() / 'workspace/Build/Linux' if source_build else BUILD
        for source, name in [
            (prepared / 'src/rustdesk/LICENCE', 'rustdesk.txt'),
            (prepared / 'src/ffmpeg-9.0.2/COPYING.LGPLv2.1', 'ffmpeg.txt'),
            (prepared / 'src/libdrmtap/LICENSE', 'libdrmtap.txt'),
        ]:
            if not source.exists() and source.name == 'LICENCE':
                source = source.with_name('LICENSE')
            copy(source, staged, 'licenses/' + name)
        native_notice_delivery.prepare(ROOT, receipt['sources'], staged / 'licenses/dependencies')
        notice_manifest = staged / 'licenses/dependencies/manifest.json'
        # Carry the exact local changes as well as pins. Full corresponding
        # dependency source/licenses remain a publication gate, stated below.
        for folder in ('Linux/gui', 'Linux/native', 'Linux/src', 'Linux/patches',
                       'Linux/packaging', 'Linux/docs', 'Linux/tests', 'Linux/notices', 'Scripts/linux'):
            for source in sorted((ROOT / folder).rglob('*')):
                if '__pycache__' in source.parts or not source.is_file():
                    continue
                copy(source, staged, 'source/' + source.relative_to(ROOT).as_posix(),
                     executable=bool(source.stat().st_mode & 0o111))
        copy(ROOT / 'Linux/Cargo.lock', staged, 'source/Linux/Cargo.lock')
        copy(ROOT / 'Linux/native-notice-supplements.json', staged, 'source/Linux/native-notice-supplements.json')
        (staged / 'build.json').write_text(json.dumps({
            'schema': 1, 'input_binaries': origin_hashes, 'packaged_binaries': binaries,
            'source_head': source_origin.get('head'),
            'source_dirty': True if source_origin['kind'] == 'git' else None,
            'source_origin': source_origin, 'source_build': source_proof, 'features': bundle.FEATURES,
            'build_receipt': receipt,
            'notice_delivery_manifest_sha256': bundle.digest(notice_manifest),
            'tooling': {name: subprocess.check_output([name, '--version'], text=True).splitlines()[0]
                        for name in ('readelf', 'patchelf')},
            'acceptance': {'runtime_ready': False, 'clean_distro_runtime': False,
                           'complete_license_source_audit': False, 'installer_rollback': False},
        }, indent=2) + '\n')
        if version is not None:
            (staged / 'release-info.json').write_text(json.dumps({
                'schema': 1, 'version': version,
                'core_sha256': binaries['libexec/farpane-core']['sha256'],
            }, indent=2) + '\n')
        (staged / 'README.txt').write_text(
            'FarPane native development bundle — NOT an accepted or published release.\n'
            'Includes GTK4/libadwaita GUI, native core, static FFmpeg and private libdrmtap.\n'
            'Requires x86_64 Linux 6.5+, GTK >= 4.14, libadwaita >= 1.5 and system graphics/audio libraries.\n'
            'Target distribution support is pending clean runtime tests. No RustDesk install or host FFmpeg is required.\n'
            'Run only from a root-owned immutable release; extracting into a user directory is insufficient.\n'
            'Desktop/D-Bus/systemd files are TEMPLATES: @FARPANE_RELEASE@ must name that exact release.\n'
            'This bundle performs no install, service activation, configuration migration or host changes.\n'
            'Keep the existing FarPane installation until coordinated upgrade/rollback is tested.\n'
            'Memory, full desktop/media/lifecycle, ABI, installer and complete dependency license/source gates remain open.\n'
            'Inspected third-party materials and unresolved records are retained in licenses/dependencies/README.txt.\n'
            'Source documentation is a snapshot; manifest.json and build.json identify this exact bundle.\n'
            'Do not publish this candidate as a completed product. See source/Linux/docs/gui-status.md.\n')
        for path in [staged, *staged.rglob('*')]:
            if path.is_dir():
                path.chmod(0o755)
            elif path.is_file() and not path.is_symlink():
                path.chmod(0o755 if path.stat().st_mode & 0o111 else 0o644)
        if origin_hashes != {name: bundle.digest(path) for name, path in inputs.items()}:
            raise ValueError('Build inputs changed during packaging')
        if source_build:
            after = source_module.load(source_build, receipt_module.sources())
            if after != (receipt, inputs, source_proof):
                raise ValueError('Source build changed during packaging')
        elif receipt_module.verify(BUILD / 'native-build.json') != receipt:
            raise ValueError('Build receipt changed during packaging')
        if source_module.identity(ROOT) != source_origin:
            raise ValueError('Packaging source identity changed')
        for name, expected in receipt['sources'].items():
            copied = staged / ('dependencies.lock.json' if name == 'Linux/dependencies.lock.json' else 'source/' + name)
            if bundle.digest(copied) != expected:
                raise ValueError('Bundled source differs from the completed build: ' + name)
        native_privacy.require_clean(staged)
        manifest = bundle.seal(staged)
        output = destination / manifest['artifact_id']
        if output.exists():
            if bundle.verify(output) != manifest:
                raise ValueError('Refusing to replace existing artifact')
        else:
            staged.rename(output)
        # Metadata normalized; the archive contains no devices or external links.
        archive = output.with_suffix('.tar.gz')
        temporary_archive = Path(temporary) / 'bundle.tar.gz'
        with temporary_archive.open('xb') as raw, gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w') as stream:
                def normalize(info):
                    info.uid = info.gid = info.mtime = 0
                    info.uname = info.gname = ''
                    return info
                stream.add(output, arcname=output.name, filter=normalize)
        native_privacy.require_clean(temporary_archive)
        if archive.exists() or archive.is_symlink():
            if archive.is_symlink() or not archive.is_file() or bundle.digest(archive) != bundle.digest(temporary_archive):
                raise ValueError('Refusing to replace a different archive')
        else:
            os.link(temporary_archive, archive)
        checksum = bundle.digest(archive) + '  ' + archive.name + '\n'
        sidecar = archive.with_name(archive.name + '.sha256')
        if sidecar.exists() or sidecar.is_symlink():
            if sidecar.is_symlink() or not sidecar.is_file() or sidecar.read_text() != checksum:
                raise ValueError('Refusing to replace a different checksum')
        else:
            with sidecar.open('x') as stream:
                stream.write(checksum)
        print(json.dumps({'artifact': str(output), 'archive': str(archive),
                          'sha256': bundle.digest(archive), 'runtime_ready': False,
                          'installed': False, 'files': len(manifest['files'])}, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--verify', type=Path, help='Verify an existing native bundle without executing it')
    mode.add_argument('--source-build', type=Path, help='Package a completed isolated source build without replacing product caches')
    parser.add_argument('--version', help='Product version displayed by this exact bundle')
    args = parser.parse_args()
    if args.verify:
        print(json.dumps(bundle.verify(args.verify), indent=2))
    else:
        package(args.source_build, args.version)
