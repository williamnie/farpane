"""Retain manually located notice texts without changing upstream declarations."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import tempfile

import native_receipt

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'Build/Linux'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def relative_path(value):
    if not isinstance(value, str) or not value or '\\' in value:
        raise ValueError('Invalid upstream notice path')
    path = Path(value)
    if path.is_absolute() or '..' in path.parts or path.as_posix() != value:
        raise ValueError('Invalid upstream notice path')
    return path


def pinned_file(path, entry):
    if path.is_symlink() or not path.is_file() or path.stat().st_size != entry['bytes']:
        raise ValueError('Upstream notice or source binding size/type differs')
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != entry['sha256']:
        raise ValueError('Upstream notice or source binding digest differs')
    blob = b'blob ' + str(len(data)).encode() + b'\0' + data
    if hashlib.sha1(blob).hexdigest() != entry['git_blob_sha1']:
        raise ValueError('Upstream notice or source binding Git blob differs')
    return data


def upstream_materials(pin, manifest, source, tree):
    upstream = pin.get('upstream')
    if upstream is None:
        return []
    repository, revision = upstream['repository'], upstream['revision']
    if (not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository)
            or not re.fullmatch(r'[0-9a-f]{40}', revision)):
        raise ValueError('Invalid pinned upstream identity')
    vcs_path = manifest.parent / '.cargo_vcs_info.json'
    if vcs_path.is_symlink() or digest(vcs_path) != upstream['cargo_vcs_info_sha256']:
        raise ValueError('Cargo source revision record differs')
    vcs = json.loads(vcs_path.read_text())
    if vcs['git']['sha1'] != revision or vcs['git'].get('dirty', False):
        raise ValueError('Upstream notice revision differs from crate source')
    bindings = upstream['source_bindings']
    if {b['kind'] for b in bindings} != {'original_manifest', 'library_source'} or len(bindings) != 2:
        raise ValueError('Upstream notice needs manifest and library source bindings')
    for binding in bindings:
        path = source / relative_path(binding['local_path'])
        origin = relative_path(binding['upstream_path'])
        expected = manifest.with_name('Cargo.toml.orig')
        if not expected.is_file():
            expected = manifest
        if binding['kind'] == 'library_source':
            expected = manifest.parent / 'src/lib.rs'
        if path != expected or not path.resolve(strict=True).is_relative_to(source):
            raise ValueError('Upstream source binding escapes package')
        if 'path_in_vcs' in vcs:
            leaf = 'src/lib.rs' if binding['kind'] == 'library_source' else 'Cargo.toml'
            if origin != Path(vcs['path_in_vcs']) / leaf:
                raise ValueError('Upstream source location differs from Cargo VCS record')
        pinned_file(path, binding)
    materials = []
    base = ROOT / 'Linux/notices/upstream' / repository.lower() / revision
    for entry in upstream['files']:
        relative = relative_path(entry['upstream_path'])
        path = ROOT / relative_path(entry['path'])
        if (path != base / relative or path.resolve(strict=True) != path
                or entry['url'] != f'https://raw.githubusercontent.com/{repository}/{revision}/{relative.as_posix()}'
                or entry['scope'] not in ('package_license_text', 'package_declaration_context')
                or not 0 < entry['bytes'] <= 256 * 1024):
            raise ValueError('Unexpected upstream notice location or scope')
        data = pinned_file(path, entry)
        material = Path('materials') / (pin['name'] + '-' + pin['version']) / 'upstream' / relative
        destination = tree / material
        destination.parent.mkdir(parents=True, exist_ok=True)
        with destination.open('xb') as stream:
            stream.write(data)
        materials.append({**entry, 'material': material.as_posix()})
    if not materials or (pin['full_package_notice_located']
                         and not any(m['scope'] == 'package_license_text' for m in materials)):
        raise ValueError('Upstream finding lacks its notice text')
    return materials


def collect(audit_path, output):
    receipt = native_receipt.verify(BUILD / 'native-build.json')
    pins_path = ROOT / 'Linux/native-notice-supplements.json'
    pins = json.loads(pins_path.read_text())
    audit_path = Path(audit_path).resolve(strict=True)
    output = Path(output).resolve()
    if not audit_path.is_relative_to(BUILD) or not output.is_relative_to(BUILD):
        raise ValueError('Notice inputs and generated outputs must remain under Build/Linux')
    if digest(audit_path) != pins['baseline_audit_sha256']:
        raise ValueError('Notice pins refer to a different baseline inventory')
    audit = json.loads(audit_path.read_text())
    if audit['binary_sha256'] != receipt['binaries']:
        raise ValueError('Baseline inventory does not describe current product binaries')
    packages = {p['id']: p for p in audit['cargo_packages']}
    missing = {i['package'] for i in audit['issues']
               if i['kind'] == 'no_matching_package_or_ancestor_notice_file'}
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.notices-', dir=output) as temporary:
        tree = Path(temporary)
        findings = []
        for pin in pins['packages']:
            package = packages[pin['package_id']]
            if package['name'] != pin['name'] or package['version'] != pin['version']:
                raise ValueError('Notice pin package identity differs')
            manifest = (ROOT / package['manifest']).resolve(strict=True)
            source = (ROOT / package['source_root']).resolve(strict=True)
            if not source.is_relative_to(BUILD) or not manifest.is_relative_to(source):
                raise ValueError('Baseline source path escapes build tree')
            if digest(manifest) != pin['manifest_sha256']:
                raise ValueError('Package manifest differs from inspected notice pin')
            materials = []
            for entry in pin['files']:
                relative = Path(entry['path'])
                if relative.is_absolute() or '..' in relative.parts or relative.as_posix() != entry['path']:
                    raise ValueError('Invalid notice source path')
                path = source / relative
                if path.is_symlink() or not path.resolve(strict=True).is_relative_to(source):
                    raise ValueError('Notice source escapes its package')
                if (not path.is_file() or path.stat().st_size != entry['bytes']
                        or digest(path) != entry['sha256']):
                    raise ValueError('Notice source differs from inspected pin: ' + str(path))
                material = Path('materials') / (pin['name'] + '-' + pin['version']) / relative
                destination = tree / material
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, destination)
                if digest(destination) != entry['sha256']:
                    raise ValueError('Notice source changed during collection')
                materials.append({**entry, 'material': material.as_posix()})
            materials.extend(upstream_materials(pin, manifest, source, tree))
            if pin['full_package_notice_located'] and pin['package_id'] not in missing:
                raise ValueError('Full-notice followup has no matching baseline record')
            findings.append({'package_id': pin['package_id'], 'source': package['source'],
                             'declared_license': package['declared_license'],
                             'finding': pin['finding'], 'materials': materials,
                             'upstream': pin.get('upstream'),
                             'full_package_notice_located': pin['full_package_notice_located']})
        located = sum(f['full_package_notice_located'] for f in findings)
        report = {'schema': 1, 'baseline_audit_sha256': digest(audit_path),
                  'pins_sha256': digest(pins_path), 'binary_sha256': receipt['binaries'],
                  'baseline_issues': audit['issues'], 'findings': findings,
                  'full_package_notice_locations_added': located,
                  'baseline_records_without_full_notice_location_followup': len(audit['issues']) - located,
                  'upstream_declarations_modified': False, 'legal_conclusions_inferred': False,
                  'complete_license_source_audit': False, 'scope': pins['scope']}
        raw = json.dumps(report, sort_keys=True, indent=2) + '\n'
        (tree / 'report.json').write_text(raw)
        shutil.copyfile(pins_path, tree / 'notice-pins.json')
        lines = [digest(p) + '  ' + p.relative_to(tree).as_posix()
                 for p in sorted(tree.rglob('*')) if p.is_file()]
        (tree / 'SHA256SUMS').write_text('\n'.join(lines) + '\n')
        if native_receipt.verify(BUILD / 'native-build.json') != receipt:
            raise ValueError('Product build changed during collection')
        target = output / ('native-notice-supplements-' + hashlib.sha256(raw.encode()).hexdigest()[:24])
        if target.exists():
            raise ValueError('Notice collection already exists; preserving prior result')
        tree.rename(target)
        return {'collection': str(target), 'packages': len(findings),
                'material_references': sum(len(f['materials']) for f in findings),
                'indexed_files': len(lines), 'full_package_notice_locations_added': located,
                'baseline_records_without_full_notice_location_followup': len(audit['issues']) - located,
                'complete_license_source_audit': False}
