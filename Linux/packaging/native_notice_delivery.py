"""Deliver inspected dependency materials with source and binary candidates."""
import hashlib
import json
from pathlib import Path
import shutil
import tempfile


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def source_digest(sources):
    return hashlib.sha256(json.dumps(sources, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def relative(value):
    if (not isinstance(value, str) or not value or '\\' in value
            or any(ord(c) < 32 or ord(c) == 127 for c in value)):
        raise ValueError('Invalid notice material path')
    path = Path(value)
    if path.is_absolute() or '..' in path.parts or path.as_posix() != value:
        raise ValueError('Invalid notice material path')
    return path


def index(root):
    result = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise ValueError('Notice delivery cannot contain symlinks')
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError('Unexpected notice material type')
        name = path.relative_to(root).as_posix()
        relative(name)
        if name != 'manifest.json':
            result[name] = {'bytes': path.stat().st_size, 'sha256': digest(path)}
    return result


def gui_source_baseline(sources, update):
    """Reuse dependency materials only for a GUI Rust-file delta.

    Cargo manifests/locks, C bridges, core and dependency sources must remain
    byte-identical. This does not close any outstanding license audit item.
    """
    if not update:
        return sources
    baseline = update.get('base_sources', {})
    if update.get('schema') != 1 or not baseline.keys() <= sources.keys():
        raise ValueError('GUI notice update changed the source inventory')
    for name in sources:
        relative(name)
    changed = sorted(k for k in sources if baseline.get(k) != sources[k])
    if (not changed or changed != update.get('changed_sources')
            or any(not k.startswith('Linux/gui/src/') or not k.endswith('.rs') for k in changed)):
        raise ValueError('GUI notice update changed dependency or non-GUI sources')
    return baseline


def rebind_gui_sources(directory, sources, pins_sha256):
    directory = Path(directory)
    baseline = json.loads((directory/'inventory/materials/Build/Linux/native-build.json').read_text())['sources']
    before = verify(directory, baseline, pins_sha256)
    if before.get('gui_source_update'):
        raise ValueError('GUI notice updates require the original baseline')
    update = {'schema': 1, 'base_sources': baseline,
              'changed_sources': sorted(k for k in sources if baseline.get(k) != sources[k])}
    gui_source_baseline(sources, update)
    before['gui_source_update'] = update
    before['application_source_map_sha256'] = source_digest(sources)
    (directory/'manifest.json').write_text(json.dumps(before, indent=2)+'\n')
    return verify(directory, sources, pins_sha256)


def verify(directory, sources, pins_sha256):
    directory = Path(directory)
    if directory.is_symlink() or (directory/'manifest.json').is_symlink():
        raise ValueError('Notice delivery root/manifest cannot be a symlink')
    manifest = json.loads((directory/'manifest.json').read_text())
    if (manifest.get('schema') != 1 or manifest.get('kind') != 'farpane-native-notice-delivery'
            or manifest.get('application_source_map_sha256') != source_digest(sources)
            or manifest.get('notice_pins_sha256') != pins_sha256
            or manifest.get('complete_license_source_audit') is not False):
        raise ValueError('Notice delivery does not match the application source/notice pins')
    if index(directory) != manifest['files']:
        raise ValueError('Notice delivery file inventory differs')
    required = {'README.txt', 'inventory/report.json', 'supplements/report.json', 'supplements/notice-pins.json'}
    if not required <= manifest['files'].keys():
        raise ValueError('Notice delivery lacks its source records')
    if digest(directory/'supplements/notice-pins.json') != pins_sha256:
        raise ValueError('Delivered notice pins differ')
    audit = json.loads((directory/'inventory/report.json').read_text())
    supplement = json.loads((directory/'supplements/report.json').read_text())
    if (digest(directory/'inventory/report.json') != manifest['inventory_sha256']
            or supplement['baseline_audit_sha256'] != manifest['inventory_sha256']
            or supplement['pins_sha256'] != pins_sha256
            or supplement['binary_sha256'] != audit['binary_sha256']):
        raise ValueError('Notice delivery report provenance differs')
    baseline = gui_source_baseline(sources, manifest.get('gui_source_update'))
    if (json.loads((directory/'inventory/materials/Build/Linux/native-build.json').read_text())['sources'] != baseline):
        raise ValueError('Notice inventory describes different application sources')
    for name, entry in audit['materials'].items():
        if manifest['files'].get('inventory/materials/'+str(relative(name))) != entry:
            raise ValueError('Notice inventory material differs from its report')
    return manifest


def assemble(audit_path, supplement_path, sources, pins_sha256, target):
    audit_path, supplement_path, target = map(Path, (audit_path, supplement_path, target))
    audit = json.loads(audit_path.read_text())
    supplement = json.loads((supplement_path/'report.json').read_text())
    if (supplement['baseline_audit_sha256'] != digest(audit_path)
            or supplement['pins_sha256'] != pins_sha256
            or supplement['binary_sha256'] != audit['binary_sha256']):
        raise ValueError('Notice supplement refers to a different inventory')
    recorded = audit_path.parent/'materials/Build/Linux/native-build.json'
    if json.loads(recorded.read_text())['sources'] != sources:
        raise ValueError('Notice inventory describes different application sources')
    target.mkdir(parents=True, exist_ok=False)
    (target/'inventory').mkdir()
    shutil.copyfile(audit_path, target/'inventory/report.json')
    for name, expected in audit['materials'].items():
        source = audit_path.parent/'materials'/relative(name)
        if (source.is_symlink() or not source.resolve(strict=True).is_relative_to(audit_path.parent.resolve())
                or source.stat().st_size != expected['bytes'] or digest(source) != expected['sha256']):
            raise ValueError('Inventory source material differs: '+name)
        destination = target/'inventory/materials'/name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    # The collection is already pinned; retain its exact index, including
    # unresolved records and original source/package scopes.
    expected_files = {}
    for line in (supplement_path/'SHA256SUMS').read_text().splitlines():
        checksum, name = line.split('  ', 1)
        if name in expected_files:
            raise ValueError('Duplicate supplement material')
        path = supplement_path/relative(name)
        if path.is_symlink() or digest(path) != checksum:
            raise ValueError('Supplement material differs')
        expected_files[name] = checksum
    actual = {str(p.relative_to(supplement_path)) for p in supplement_path.rglob('*') if p.is_file()}
    if actual != set(expected_files) | {'SHA256SUMS'} or any(p.is_symlink() for p in supplement_path.rglob('*')):
        raise ValueError('Supplement material set differs')
    shutil.copytree(supplement_path, target/'supplements')
    (target/'README.txt').write_text(
        'FarPane dependency source and notice materials\n\n'
        'inventory/ contains the original selected Cargo graph and native dependency materials.\n'
        'supplements/ retains additional original texts at inspected local or fixed upstream locations.\n'
        'Build-only and inactive dependencies can occur here; this is not a linked-object inventory.\n'
        'Declarations, copyright lines and nested-component scopes remain unchanged.\n'
        'The original inventory binary hashes identify the inspected build, not a later rebuild.\n'
        'This delivery binds to the exact application source map and notice pins; a rebuild can have different bytes.\n'
        'Unresolved records remain explicit. This is not a complete license/source release audit.\n')
    manifest = {'schema': 1, 'kind': 'farpane-native-notice-delivery',
                'application_source_map_sha256': source_digest(sources), 'notice_pins_sha256': pins_sha256,
                'inventory_sha256': digest(audit_path), 'audited_binary_sha256': audit['binary_sha256'],
                'cargo_packages': len(audit['cargo_packages']), 'original_inventory_records': len(audit['issues']),
                'full_notice_locations_added': supplement['full_package_notice_locations_added'],
                'records_without_full_notice_followup': supplement['baseline_records_without_full_notice_location_followup'],
                'complete_license_source_audit': False, 'files': index(target)}
    (target/'manifest.json').write_text(json.dumps(manifest, sort_keys=True, indent=2)+'\n')
    return verify(target, sources, pins_sha256)


def prepare(project, sources, target):
    """Use an archive's frozen delivery, or assemble from the local audit once."""
    project, target = Path(project), Path(target)
    pins = project/'Linux/native-notice-supplements.json'
    pins_sha256 = digest(pins)
    frozen = project/'native-dependencies/notice-delivery'
    if (project/'source-manifest.json').is_file():
        source_manifest = json.loads((project/'source-manifest.json').read_text())
        entry = source_manifest['files'].get('native-dependencies/notice-delivery/manifest.json')
        if not entry or entry['sha256'] != digest(frozen/'manifest.json'):
            raise ValueError('Source snapshot does not bind its frozen notice delivery')
        verify(frozen, sources, pins_sha256)
        shutil.copytree(frozen, target)
        return verify(target, sources, pins_sha256)
    build = project/'Build/Linux'
    data = json.loads(pins.read_text())
    audit = build/'source-audit'/('native-source-audit-'+data['baseline_audit_sha256'][:24])/'report.json'
    if digest(audit) != data['baseline_audit_sha256']:
        raise ValueError('Baseline notice inventory hash differs')
    import native_notice_supplements
    with tempfile.TemporaryDirectory(prefix='.notice-delivery-', dir=build) as temporary:
        collected = native_notice_supplements.collect(audit, Path(temporary))
        return assemble(audit, Path(collected['collection']), sources, pins_sha256, target)
