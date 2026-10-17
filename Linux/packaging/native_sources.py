"""Inventory pinned native source/license materials without inferring permissions."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import tempfile

import native_receipt

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'Build/Linux'
NOTICE = re.compile(r'^(licen[cs]e|copying|copyright|notice|unlicense)([._-].*)?$', re.I)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def local_path(value):
    path = ROOT / Path(value).relative_to('/workspace')
    if not path.resolve(strict=True).is_relative_to(BUILD):
        raise ValueError('Metadata source is outside the isolated build tree')
    return path


def selected(metadata):
    nodes = {node['id']: node for node in metadata['resolve']['nodes']}
    pending = [metadata['resolve']['root']]
    visited = set()
    while pending:
        identifier = pending.pop()
        if identifier in visited:
            continue
        visited.add(identifier)
        pending.extend(dep['pkg'] for dep in nodes[identifier]['deps']
                       if any(kind['kind'] != 'dev' for kind in dep['dep_kinds']))
    return visited


def source_root(package, manifest):
    source = package.get('source') or ''
    if source.startswith('git+'):
        relative = manifest.relative_to(BUILD / 'cargo/git/checkouts')
        return BUILD / 'cargo/git/checkouts' / Path(*relative.parts[:2])
    if source.startswith('registry+'):
        return manifest.parent
    # hbb_common is independently pinned, even though placed under RustDesk.
    for name in ('src/rustdesk/libs/hbb_common', 'src/rustdesk', 'src/hwcodec',
                 'src/clipboard_master', 'gui', 'native/protocol', 'native/files'):
        root = BUILD / name
        if manifest.is_relative_to(root):
            return root
    raise ValueError('Unrecognized path dependency source: ' + str(manifest))


def notice_files(package, manifest, root):
    candidates = set()
    directory = manifest.parent
    while directory.is_relative_to(root):
        for path in directory.iterdir():
            if path.is_file() and NOTICE.fullmatch(path.name):
                candidates.add(path)
        if directory == root:
            break
        directory = directory.parent
    if package.get('license_file'):
        path = Path(package['license_file'])
        path = local_path(str(path)) if path.is_absolute() else manifest.parent / path
        if not path.resolve(strict=True).is_relative_to(root.resolve()):
            raise ValueError('Declared license file escapes its source root')
        candidates.add(path)
    resolved = set()
    for path in candidates:
        actual = path.resolve(strict=True)
        if not actual.is_relative_to(root.resolve()):
            raise ValueError('Notice symlink escapes its source root')
        resolved.add(actual)
    return sorted(resolved)


def inventory(core_path, gui_path, destination):
    receipt = native_receipt.verify(BUILD / 'native-build.json')
    destination = Path(destination).resolve()
    if not destination.is_relative_to(BUILD):
        raise ValueError('Source audit output must remain under Build/Linux')
    metadata = {name: json.loads(Path(path).read_text())
                for name, path in [('core', core_path), ('gui', gui_path)]}
    core_root = metadata['core']['resolve']['root']
    features = next(n['features'] for n in metadata['core']['resolve']['nodes'] if n['id'] == core_root)
    if not {'farpane-native', 'linux-gpu-media'} <= set(features) or {'flutter', 'sciter'} & set(features):
        raise ValueError('Metadata does not describe the native release features')
    packages = {}
    owners = {}
    counts = {}
    for component, data in metadata.items():
        wanted = selected(data)
        counts[component] = len(wanted)
        for package in data['packages']:
            identifier = package['id']
            if identifier not in wanted:
                continue
            if identifier in packages and packages[identifier] != package:
                raise ValueError('Conflicting Cargo metadata for ' + identifier)
            packages[identifier] = package
            owners.setdefault(identifier, []).append(component)
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.audit-', dir=destination) as temporary:
        tree = Path(temporary)
        material = {}
        issues = []
        def retain(path):
            path = Path(path)
            if path.is_symlink() or not path.is_file() or path.stat().st_size > 8 * 1024 * 1024:
                raise ValueError('Invalid notice/material file: ' + str(path))
            name = path.relative_to(ROOT).as_posix()
            checksum = digest(path)
            target = tree / 'materials' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
            if digest(target) != checksum:
                raise ValueError('Source material changed while reading')
            material[name] = {'sha256': checksum, 'bytes': path.stat().st_size}
            return name
        entries = []
        for identifier, package in sorted(packages.items()):
            manifest = local_path(package['manifest_path'])
            root = source_root(package, manifest)
            notices = [retain(path) for path in notice_files(package, manifest, root)]
            if not package.get('source') and root.is_relative_to(BUILD) and root.parts[-1] in ('gui', 'protocol', 'files'):
                notices.append(retain(ROOT / 'LICENSE'))
            entry = {'id': identifier, 'name': package['name'], 'version': package['version'],
                     'components': owners[identifier], 'source': package.get('source'),
                     'repository': package.get('repository'),
                     'source_root': root.relative_to(ROOT).as_posix(),
                     'manifest': retain(manifest), 'declared_license': package.get('license'),
                     'declared_license_file': package.get('license_file'), 'notice_files': notices}
            vcs = manifest.parent / '.cargo_vcs_info.json'
            if vcs.is_file():
                entry['cargo_vcs_info'] = retain(vcs)
            entries.append(entry)
            if not package.get('license') and not package.get('license_file'):
                issues.append({'package': identifier, 'kind': 'missing_manifest_license_declaration'})
            if not notices:
                issues.append({'package': identifier, 'kind': 'no_matching_package_or_ancestor_notice_file'})
        lock = json.loads((ROOT / 'Linux/dependencies.lock.json').read_text())
        for name in ('Linux/dependencies.lock.json', 'Linux/Cargo.lock', 'Linux/gui/Cargo.lock',
                     'Build/Linux/native-build.json', 'Linux/packaging/native_sources.py'):
            retain(ROOT / name)
        ffmpeg = BUILD / ('src/ffmpeg-' + lock['ffmpeg']['version'])
        ffmpeg_files = [retain(p) for p in sorted(ffmpeg.iterdir()) if p.is_file() and NOTICE.fullmatch(p.name)]
        config = BUILD / 'ffmpeg-build/config.h'
        flags = {key: re.search(r'^#define ' + key + r' (.+)$', config.read_text(), re.M).group(1)
                 for key in ('FFMPEG_LICENSE', 'CONFIG_GPL', 'CONFIG_NONFREE', 'CONFIG_VERSION3')}
        retain(config)
        retain(BUILD / 'ffmpeg-build/ffbuild/config.mak')
        ports = []
        for port in sorted((BUILD / 'vcpkg/installed/x64-linux/share').iterdir()):
            if not port.is_dir():
                continue
            # These cached ports precede the explicit FFmpeg/AMF replacement.
            if port.name in ('ffmpeg', 'amd-amf'):
                continue
            files = [retain(port / name) for name in ('copyright', 'vcpkg.spdx.json',
                     'vcpkg-spdx-resources.json', 'vcpkg_abi_info.txt') if (port / name).is_file()]
            if files:
                ports.append({'name': port.name, 'materials': files})
        retain(BUILD / 'src/libdrmtap/LICENSE')
        # AMF carries its notice in the headers, not a top-level LICENSE.txt.
        amf_header = retain(BUILD / ('src/AMF-' + lock['amf_headers']['version']) /
                            'amf/public/include/core/Factory.h')
        archives = []
        for name, pin in [('ffmpeg-' + lock['ffmpeg']['version'] + '.tar.xz', lock['ffmpeg']),
                          ('AMF-v' + lock['amf_headers']['version'] + '.tar.gz', lock['amf_headers'])]:
            path = BUILD / 'downloads' / name
            checksum = digest(path)
            if checksum != pin['sha256']:
                raise ValueError('Pinned native source archive differs: ' + name)
            archives.append({'path': path.relative_to(ROOT).as_posix(), 'sha256': checksum,
                             'bytes': path.stat().st_size, 'included_in_this_inventory': False})
        retain(Path(core_path).resolve())
        retain(Path(gui_path).resolve())
        report = {'schema': 1, 'binary_sha256': receipt['binaries'], 'core_features': features,
                  'metadata_sha256': {'core': digest(Path(core_path)), 'gui': digest(Path(gui_path))},
                  'component_counts': counts, 'cargo_packages': entries, 'issues': issues,
                  'ffmpeg': {'version': lock['ffmpeg']['version'], 'configuration': flags, 'notices': ffmpeg_files},
                  'amf_header_notice': amf_header, 'available_verified_native_archives': archives,
                  'cached_ports': ports, 'materials': material,
                  'complete_license_source_audit': False, 'legal_conclusions_inferred': False,
                  'scope': 'Resolved non-dev Cargo edges including build dependencies; top-level/ancestor notices and cached native port materials. Not an exact linked-object SBOM or complete nested third-party notice/source archive.'}
        raw = json.dumps(report, sort_keys=True, indent=2) + '\n'
        (tree / 'report.json').write_text(raw)
        index = [digest(path) + '  ' + path.relative_to(tree).as_posix()
                 for path in sorted(tree.rglob('*')) if path.is_file()]
        (tree / 'SHA256SUMS').write_text('\n'.join(index) + '\n')
        identity = 'native-source-audit-' + hashlib.sha256(raw.encode()).hexdigest()[:24]
        target = destination / identity
        if target.exists():
            raise ValueError('Audit output already exists; inspect the preserved result')
        tree.rename(target)
        return {'audit': str(target), 'cargo_packages': len(entries), 'component_counts': counts,
                'materials': len(material), 'issues': len(issues), 'complete_license_source_audit': False}
