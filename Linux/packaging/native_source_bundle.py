"""Assemble pinned source snapshots; no builds, service access or network calls."""
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile

import native_receipt
import native_notice_supplements
import native_notice_delivery
import native_package_source

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'Build/Linux'
LOCK = json.loads((ROOT / 'Linux/dependencies.lock.json').read_text())
PINS = json.loads((ROOT / 'Linux/native-source-pins.json').read_text())


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def git(repo, *args, **kwargs):
    return subprocess.run(['git', '-c', 'safe.directory=' + str(repo), '-C', str(repo), *args],
                          check=True, **kwargs)


def export(repo, revision, target, marker=False):
    if not repo.is_dir():
        raise ValueError('Missing read-only pinned Git source: ' + str(repo))
    target.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryFile() as stream:
        git(repo, 'archive', '--format=tar', revision, stdout=stream)
        stream.seek(0)
        with tarfile.open(fileobj=stream) as archive:
            archive.extractall(target, filter='data')
    if marker:
        (target / '.farpane-source-pin').write_text(revision + '\n')


def one(paths):
    paths = list(paths)
    if len(paths) != 1:
        raise ValueError('Expected one pinned local checkout, found ' + str(len(paths)))
    return paths[0]


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


LEGACY_BUILD_OUTPUTS = ('flutter/.dart_tool', 'flutter/build', 'flutter/.flutter-plugins',
                        'flutter/.flutter-plugins-dependencies', 'flutter/linux/flutter/ephemeral',
                        'flutter/windows/flutter/ephemeral', 'flutter/macos/Flutter/ephemeral',
                        'flutter/android/local.properties',
                        'flutter/android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java',
                        'flutter/ios/Flutter/Generated.xcconfig', 'flutter/ios/Flutter/flutter_export_environment.sh',
                        'flutter/ios/Runner/GeneratedPluginRegistrant.h', 'flutter/ios/Runner/GeneratedPluginRegistrant.m',
                        'flutter/lib/generated_bridge.dart', 'flutter/lib/generated_bridge.freezed.dart',
                        'flutter/linux/flutter/generated_plugin_registrant.cc',
                        'flutter/linux/flutter/generated_plugin_registrant.h', 'flutter/linux/flutter/generated_plugins.cmake',
                        'flutter/windows/flutter/generated_plugin_registrant.cc',
                        'flutter/windows/flutter/generated_plugin_registrant.h', 'flutter/windows/flutter/generated_plugins.cmake',
                        'flutter/macos/Flutter/GeneratedPluginRegistrant.swift',
                        'src/bridge_generated.rs', 'src/bridge_generated.io.rs')


def index(root, ignore=()):
    result = {}
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if '__pycache__' in relative.parts or '.git' in relative.parts:
            continue
        name = relative.as_posix()
        if any(name == prefix or name.startswith(prefix + '/') for prefix in ignore):
            continue
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            link = path.readlink()
            if link.is_absolute() or not path.resolve(strict=True).is_relative_to(root.resolve()):
                raise ValueError('Source symlink escapes snapshot: ' + name)
            result[name] = {'symlink': str(link)}
        elif stat.S_ISREG(mode):
            result[name] = {'sha256': digest(path), 'bytes': path.stat().st_size,
                            'executable': bool(mode & 0o111)}
        elif not stat.S_ISDIR(mode):
            raise ValueError('Unexpected source entry: ' + name)
    return result


def reconstructed(tree, reference, prepared_build=BUILD):
    sources = tree / 'Build/Linux/src'
    hwcodec = one((reference / 'cache/cargo/git/checkouts').glob('hwcodec-*/' + LOCK['hwcodec']['commit'][:7]))
    clipboard = one((BUILD / 'cargo/git/checkouts').glob('clipboard-master-*/' + LOCK['clipboard_master']['commit'][:7]))
    origins = {
        'rustdesk': (reference / 'rustdesk', 'rustdesk'),
        'hbb_common': (reference / 'rustdesk/libs/hbb_common', 'rustdesk/libs/hbb_common'),
        'hwcodec': (hwcodec, 'hwcodec'),
        'hwcodec_externals': (hwcodec / 'externals', 'hwcodec/externals'),
        'clipboard_master': (clipboard, 'clipboard_master'),
        'libdrmtap': (BUILD / 'git/libdrmtap', 'libdrmtap'),
    }
    for name, (origin, relative) in origins.items():
        export(origin, LOCK[name]['commit'], sources / relative, marker=True)
    ffmpeg = 'ffmpeg-' + LOCK['ffmpeg']['version']
    source_archive = BUILD / 'downloads' / (ffmpeg + '.tar.xz')
    if digest(source_archive) != LOCK['ffmpeg']['sha256']:
        raise ValueError('FFmpeg source archive differs from pin')
    with tarfile.open(source_archive) as archive:
        archive.extractall(sources, filter='data')
    spec = importlib.util.spec_from_file_location('prepare_sources', ROOT / 'Scripts/linux/prepare.py')
    prepare = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(prepare)
    for entry in LOCK['patches']:
        patch = ROOT / entry['path']
        if digest(patch) != entry['sha256']:
            raise ValueError('Canonical patch differs from pin')
        target = entry.get('target', 'rustdesk')
        prepare.apply_patch(sources / (ffmpeg if target == 'ffmpeg' else target), patch)
    for entry in LOCK['overlays']:
        source = ROOT / entry['path']
        if digest(source) != entry['sha256']:
            raise ValueError('Canonical overlay differs from pin')
        copy(source, sources / 'rustdesk' / entry['target'])
    for entry in LOCK['lockfiles']:
        source = ROOT / entry['path']
        if digest(source) != entry['sha256']:
            raise ValueError('Canonical lock differs from pin')
        relative = 'Cargo.lock' if source.name == 'Cargo.lock' else 'flutter/pubspec.lock'
        copy(source, sources / 'rustdesk' / relative)
    comparisons = {}
    for name in ('rustdesk', 'hwcodec', 'clipboard_master', 'libdrmtap', ffmpeg):
        # gen_version() writes this source on every Cargo build/check, including
        # its date. Keep the observed file, but do not claim it came from Git.
        ignored = LEGACY_BUILD_OUTPUTS + ('src/version.rs',) if name == 'rustdesk' else ()
        expected, actual = index(sources / name, ignored), index(prepared_build / 'src' / name, ignored)
        changed = sorted(k for k in set(expected) | set(actual) if expected.get(k) != actual.get(k))
        if changed:
            raise ValueError('Generated source has changes outside canonical reconstruction: ' + name + ' ' + repr(changed[:30]))
        comparisons[name] = len(expected)
    copy(prepared_build / 'src/rustdesk/src/version.rs', sources / 'rustdesk/src/version.rs')
    for relative in ('gui', 'native/protocol', 'native/files'):
        shutil.copytree(ROOT / 'Linux' / relative, tree / 'Build/Linux' / relative)
        if index(tree / 'Build/Linux' / relative) != index(prepared_build / relative):
            raise ValueError('Native staging differs from canonical files: ' + relative)
    copy(prepared_build / 'native-source-map.json', tree / 'Build/Linux/native-source-map.json')
    return comparisons


def verify_vendor(tree, files):
    checked = 0
    for package in sorted((tree / 'vendor').iterdir()):
        if not package.is_dir() or package.is_symlink():
            raise ValueError('Unexpected Cargo vendor entry')
        checksums = json.loads((package / '.cargo-checksum.json').read_text())['files']
        prefix = 'vendor/' + package.name + '/'
        actual = {name.removeprefix(prefix) for name in files if name.startswith(prefix)}
        if actual != set(checksums) | {'.cargo-checksum.json'}:
            raise ValueError('Cargo vendor file inventory differs: ' + package.name)
        for name, expected in checksums.items():
            relative = Path(name)
            if relative.is_absolute() or '..' in relative.parts or relative.as_posix() != name:
                raise ValueError('Invalid Cargo vendor checksum path')
            entry = files[prefix + name]
            checksum = digest(package / name) if 'symlink' in entry else entry['sha256']
            if checksum != expected:
                raise ValueError('Cargo vendor source checksum mismatch: ' + prefix + name)
            checked += 1
    return checked


def native_materials(tree, reference):
    if PINS['upstream_commits'] != {name: LOCK[name]['commit'] for name in PINS['upstream_commits']}:
        raise ValueError('Native recipe pins refer to different upstream commits')
    roots = {'rustdesk': reference / 'rustdesk', 'vcpkg': reference / 'vcpkg'}
    for name, entry in PINS['ports'].items():
        destination = tree / 'native-dependencies/ports' / name
        export(roots[entry['origin']], entry['git_tree'], destination)
        files = index(destination)
        if {key: value.get('sha256') for key, value in files.items()} != entry['files']:
            raise ValueError('Pinned port tree differs: ' + name)
        abi = BUILD / 'vcpkg/installed/x64-linux/share' / name / 'vcpkg_abi_info.txt'
        if digest(abi) != entry['abi_record_sha256']:
            raise ValueError('Installed native ABI record differs: ' + name)
        copy(abi, tree / 'native-dependencies/build-records' / name / abi.name)
    for entry in PINS['archives']:
        source = reference / 'vcpkg/downloads' / entry['filename']
        if digest(source) != entry['sha256'] or source.stat().st_size != entry['bytes']:
            raise ValueError('Native source archive differs from pin: ' + entry['filename'])
        copy(source, tree / 'native-dependencies/downloads' / source.name)
    export(reference / 'vcpkg', LOCK['vcpkg']['commit'], tree / 'native-dependencies/vcpkg')
    for name, pin in [
        ('ffmpeg-' + LOCK['ffmpeg']['version'] + '.tar.xz', LOCK['ffmpeg']),
        ('AMF-v' + LOCK['amf_headers']['version'] + '.tar.gz', LOCK['amf_headers']),
        (LOCK['meson']['filename'], LOCK['meson']),
    ]:
        source = BUILD / 'downloads' / name
        if digest(source) != pin['sha256']:
            raise ValueError('Pinned source/tool archive differs: ' + name)
        copy(source, tree / 'Build/Linux/downloads' / name)


def supplemental_notices(tree):
    # Cargo's package include filters may omit a nested dependency's license.
    # Preserve the inspected originals outside vendor; never alter its checksums.
    notice_pins = json.loads((ROOT / 'Linux/native-notice-supplements.json').read_text())
    baseline = BUILD / 'source-audit' / ('native-source-audit-' + notice_pins['baseline_audit_sha256'][:24])
    return native_notice_supplements.collect(baseline / 'report.json',
                                            tree / 'native-dependencies/notice-supplements')


def package(reference, vendor, vendor_config, output, source_build=None):
    if source_build:
        source_build = Path(source_build).resolve(strict=True)
        receipt, _, source_proof = native_package_source.load(source_build, native_receipt.sources())
        prepared_build = source_build / 'workspace/Build/Linux'
    else:
        receipt = native_receipt.verify(BUILD / 'native-build.json')
        source_proof, prepared_build = None, BUILD
    reference, vendor = Path(reference).resolve(strict=True), Path(vendor).resolve(strict=True)
    output = Path(output).resolve()
    if not output.is_relative_to(BUILD) or not vendor.is_relative_to(BUILD):
        raise ValueError('Generated source inputs/outputs must remain under Build/Linux')
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.source-', dir=output) as temporary:
        tree = Path(temporary) / 'snapshot'
        tree.mkdir()
        print('Reconstructing pinned sources and checking complete prepared trees', flush=True)
        comparisons = reconstructed(tree, reference, prepared_build)
        print('Retaining canonical sources, exact port recipes and source archives', flush=True)
        for name in ('Linux', 'Scripts/linux'):
            shutil.copytree(ROOT / name, tree / name, ignore=shutil.ignore_patterns('__pycache__'))
        # Keep the independent Linux entrypoint without collecting other
        # platforms' workflows or repository credentials/metadata.
        workflow = '.github/workflows/linux-native.yml'
        copy(ROOT / workflow, tree / workflow)
        copy(ROOT / 'LICENSE', tree / 'LICENSE')
        copy(ROOT / 'THIRD_PARTY_NOTICES.md', tree / 'THIRD_PARTY_NOTICES.md')
        native_materials(tree, reference)
        supplemental_notices(tree)
        native_notice_delivery.prepare(ROOT, receipt['sources'], tree / 'native-dependencies/notice-delivery')
        print('Retaining Cargo vendor sources; no compiler or credential cache is copied', flush=True)
        shutil.copytree(vendor, tree / 'vendor', symlinks=True)
        configuration = Path(vendor_config).read_text()
        old = 'directory = "/workspace/' + vendor.relative_to(ROOT).as_posix() + '"'
        if configuration.count(old) != 1:
            raise ValueError('Unexpected Cargo vendor directory configuration')
        configuration = configuration.replace(old, 'directory = "vendor"')
        (tree / '.cargo').mkdir()
        (tree / '.cargo/config.toml').write_text(configuration)
        (tree / 'binary-build-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        copy(ROOT / 'Linux/packaging/native-source-README.md', tree / 'README.source.md')
        print('Hashing source snapshot', flush=True)
        files = index(tree)
        vendored_files = verify_vendor(tree, files)
        manifest = {'schema': 1, 'kind': 'farpane-native-source-snapshot',
                    'binary_sha256': receipt['binaries'], 'reconstructed_source_files': comparisons,
                    'compiled_source_build': source_proof,
                    'vendor_packages': len(list(vendor.iterdir())), 'files': files,
                    'verified_vendor_source_files': vendored_files,
                    'prepared_comparison_excludes_legacy_build_outputs': list(LEGACY_BUILD_OUTPUTS),
                    'build_generated_sources': {'Build/Linux/src/rustdesk/src/version.rs':
                        'Captured current output of hbb_common::gen_version; build date is regenerated on builds/checks, not an original-release timestamp proof.'},
                    'complete_license_source_audit': False, 'fresh_full_build_verified': False,
                    'runtime_binaries_included': False}
        raw = json.dumps(manifest, sort_keys=True, separators=(',', ':')) + '\n'
        identity = 'farpane-native-source-' + hashlib.sha256(raw.encode()).hexdigest()[:24]
        (tree / 'source-manifest.json').write_text(raw)
        if source_build:
            current, _, proof = native_package_source.load(source_build, native_receipt.sources())
            if current != receipt or proof != source_proof:
                raise ValueError('Source build changed during source packaging')
        elif native_receipt.verify(BUILD / 'native-build.json') != receipt:
            raise ValueError('Product build changed during source packaging')
        target = output / identity
        if target.exists():
            raise ValueError('Source snapshot already exists; preserving prior output')
        tree.rename(target)
        archive = output / (identity + '.tar.gz')
        if archive.exists() or archive.is_symlink():
            raise ValueError('Source archive already exists')
        print('Compressing verified source snapshot: ' + identity, flush=True)
        packed = Path(temporary) / 'source.tar.gz'
        with packed.open('xb') as stream, gzip.GzipFile(filename='', fileobj=stream, mode='wb', mtime=0, compresslevel=6) as compressed:
            with tarfile.open(fileobj=compressed, mode='w|') as tar:
                def normalized(info):
                    info.uid = info.gid = info.mtime = 0
                    info.uname = info.gname = ''
                    info.mode = 0o755 if info.isdir() or info.mode & 0o111 else 0o644
                    info.pax_headers = {}
                    return info
                tar.add(target, arcname=identity, filter=normalized)
        os.link(packed, archive)
        checksum = digest(archive)
        archive.with_suffix('.gz.sha256').write_text(checksum + '  ' + archive.name + '\n')
        return {'snapshot': str(target), 'archive': str(archive), 'sha256': checksum,
                'files': len(files), 'vendor_packages': manifest['vendor_packages'],
                'complete_license_source_audit': False, 'fresh_full_build_verified': False}
