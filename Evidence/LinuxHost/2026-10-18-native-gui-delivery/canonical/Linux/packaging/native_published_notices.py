"""Verify notice location followups for crates published without VCS records."""
import hashlib
import json
from pathlib import Path
import re
import stat
import tomllib

import native_bundle
import native_notice_delivery
import native_receipt

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def blob(data):
    return hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()


def crate_files(root, *, vendor=False):
    """Cargo's cache marker and normalized manifest are not upstream sources."""
    if (root/'.cargo_vcs_info.json').exists():
        raise ValueError('Use recorded VCS provenance for this crate')
    ignored = {'.cargo-checksum.json'} if vendor else {'.cargo-ok'}
    if vendor:
        checksum = root/'.cargo-checksum.json'
        if checksum.is_symlink() or not checksum.is_file():
            raise ValueError('Expected a regular Cargo vendor checksum')
        recorded = json.loads(checksum.read_text())['files']
        actual = {}
        for path in root.rglob('*'):
            if path.is_symlink():
                raise ValueError('Unexpected published source symlink')
            if path.is_file() and path != checksum:
                actual[path.relative_to(root).as_posix()] = digest(path)
        if actual != recorded:
            raise ValueError('Cargo vendor source checksum inventory differs')
    if (root/'Cargo.toml.orig').is_file():
        ignored.add('Cargo.toml')
    files = {}
    for path in root.rglob('*'):
        if path.is_symlink():
            raise ValueError('Unexpected published source symlink')
        if not path.is_file():
            continue
        name = path.relative_to(root).as_posix()
        if name not in ignored:
            files[name] = path
    return files


def verify_crate(root, pin, tree, *, vendor=False):
    root = Path(root).resolve(strict=True)
    tree_url = f'https://api.github.com/repos/{pin["repository"]}/git/trees/{pin["revision"]}'
    if (not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', pin['repository'])
            or not re.fullmatch(r'[0-9a-f]{40}', pin['revision'])
            or tree.get('sha') != pin['revision'] or tree.get('url') != tree_url
            or pin['tree_url'] != tree_url+'?recursive=1'):
        raise ValueError('Upstream tree identity differs')
    if digest(root/'Cargo.toml') != pin['manifest_sha256']:
        raise ValueError('Published manifest differs')
    nodes = {n['path']: n for n in tree['tree'] if n['type'] == 'blob'}
    if tree.get('truncated'):
        raise ValueError('Truncated upstream tree')
    files = crate_files(root, vendor=vendor)
    expected = {e['local_path']: e for e in pin['published_files']}
    if len(expected) != len(pin['published_files']) or set(files) != set(expected):
        raise ValueError('Published source file set differs')
    for name, path in files.items():
        entry = expected[name]
        leaf = 'Cargo.toml' if name == 'Cargo.toml.orig' else name
        upstream = '/'.join(p for p in (pin['package_path'], leaf) if p)
        native_bundle.relative_path(upstream)
        node = nodes[upstream]
        data = path.read_bytes()
        if (entry['upstream_path'] != upstream or node['mode'] not in ('100644', '100755')
                or node['sha'] != entry['git_blob_sha1'] or blob(data) != node['sha']
                or len(data) != entry['bytes'] or len(data) != node['size']
                or hashlib.sha256(data).hexdigest() != entry['sha256']):
            raise ValueError('Published source differs from upstream: '+name)
    return len(files)


def verify_snapshot(snapshot, expected_sha256, sources):
    """Check the complete extracted snapshot without consulting build caches."""
    snapshot = Path(snapshot)
    manifest_path = snapshot/'source-manifest.json'
    if (snapshot.is_symlink() or manifest_path.is_symlink()
            or not re.fullmatch('[0-9a-f]{64}', expected_sha256)
            or digest(manifest_path) != expected_sha256):
        raise ValueError('Frozen source manifest identity differs')
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('schema') != 1 or manifest.get('kind') != 'farpane-native-source-snapshot':
        raise ValueError('Expected a frozen native source snapshot')
    files = {}
    for path in snapshot.rglob('*'):
        name = path.relative_to(snapshot).as_posix()
        if name == 'source-manifest.json':
            continue
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            link = path.readlink()
            if link.is_absolute() or not path.resolve(strict=True).is_relative_to(snapshot.resolve()):
                raise ValueError('Frozen source symlink escapes snapshot')
            files[name] = {'symlink': str(link)}
        elif stat.S_ISREG(mode):
            files[name] = {'sha256': digest(path), 'bytes': path.stat().st_size,
                           'executable': bool(mode & 0o111)}
        elif not stat.S_ISDIR(mode):
            raise ValueError('Unexpected frozen source entry')
    if files != manifest['files']:
        raise ValueError('Frozen source file inventory differs')
    receipt = json.loads((snapshot/'binary-build-receipt.json').read_text())
    if receipt['sources'] != sources:
        raise ValueError('Frozen source belongs to different application sources')
    for name, sha in sources.items():
        native_bundle.relative_path(name)
        if files[name].get('sha256') != sha:
            raise ValueError('Compiled canonical source differs from snapshot: '+name)
    return manifest


def verify_frozen(artifact, snapshot, manifest_sha256):
    """Revalidate the archived package proofs for a selected frozen candidate.

    Historical artifact/baseline fields remain historical. Re-establish every
    source/notice binding against this candidate and its complete source tree;
    do not modify old reports or import an active worktree build receipt.
    """
    artifact, snapshot = Path(artifact), Path(snapshot)
    if artifact.is_symlink() or snapshot.is_symlink():
        raise ValueError('Use regular frozen input directories')
    artifact, snapshot = artifact.resolve(strict=True), snapshot.resolve(strict=True)
    if (not artifact.is_relative_to(ROOT/'Build/Linux/artifacts')
            or not snapshot.is_relative_to(ROOT/'Build/Linux/source-bundles')):
        raise ValueError('Expected generated candidate/source directories under Build/Linux')
    bundle = native_bundle.verify(artifact)
    build = json.loads((artifact/'build.json').read_text())
    sources = build['build_receipt']['sources']
    source_manifest = verify_snapshot(snapshot, manifest_sha256, sources)
    pins_path = snapshot/'Linux/native-published-notices.json'
    pins = json.loads(pins_path.read_text())
    if pins.get('schema') != 1 or not pins['packages']:
        raise ValueError('Missing archived published-source proofs')
    directory = artifact/'licenses/dependencies'
    frozen_pins = directory/'supplements/notice-pins.json'
    delivery = native_notice_delivery.verify(directory, sources, digest(frozen_pins))
    if digest(directory/'manifest.json') != build['notice_delivery_manifest_sha256']:
        raise ValueError('Candidate notice delivery binding differs')
    audit = json.loads((directory/'inventory/report.json').read_text())
    packages = {p['id']: p for p in audit['cargo_packages']}
    existing = json.loads(frozen_pins.read_text())
    located = {p['package_id'] for p in existing['packages'] if p['full_package_notice_located']}
    results = []
    for pin in pins['packages']:
        package = packages[pin['package_id']]
        root = snapshot/native_bundle.relative_path(pin['source_snapshot_package'])
        if not root.is_relative_to(snapshot/'vendor'):
            raise ValueError('Published proof must refer to a vendored crate')
        cargo = tomllib.loads((root/'Cargo.toml').read_text())['package']
        if (package['name'] != pin['name'] or package['version'] != pin['version']
                or cargo['name'] != pin['name'] or cargo['version'] != pin['version']
                or cargo.get('license') != package['declared_license']):
            raise ValueError('Selected candidate package identity/declaration differs')
        tree_path = snapshot/native_bundle.relative_path(pin['tree_path'])
        if tree_path.is_symlink() or digest(tree_path) != pin['tree_sha256']:
            raise ValueError('Archived upstream tree differs')
        tree = json.loads(tree_path.read_text())
        count = verify_crate(root, pin, tree, vendor=True)
        notice = pin['notice']
        name = str(native_bundle.relative_path(notice['existing_material']))
        shipped = directory/'inventory/materials'/name
        data = shipped.read_bytes()
        node = next(n for n in tree['tree'] if n['path'] == notice['upstream_path'] and n['type'] == 'blob')
        expected_url = f'https://raw.githubusercontent.com/{pin["repository"]}/{pin["revision"]}/{notice["upstream_path"]}'
        sha = hashlib.sha256(data).hexdigest()
        if (notice['url'] != expected_url or node['mode'] != '100644'
                or notice['git_blob_sha1'] != node['sha'] or blob(data) != node['sha']
                or len(data) != node['size'] or notice['bytes'] != len(data)
                or notice['sha256'] != sha
                or audit['materials'][name] != {'bytes': len(data), 'sha256': sha}):
            raise ValueError('Candidate notice differs from the pinned upstream text')
        if (pin['package_id'] in located or
                {'package': pin['package_id'], 'kind': 'no_matching_package_or_ancestor_notice_file'} not in audit['issues']):
            raise ValueError('Duplicate or inapplicable notice followup')
        located.add(pin['package_id'])
        results.append({'package_id': pin['package_id'], 'published_files_verified': count,
                        'upstream_commit': pin['revision'], 'notice_sha256': sha,
                        'already_in_candidate': True, 'vendored_sources_verified': True})
    return {'schema': 1, 'result': 'pass', 'mode': 'frozen-candidate-and-source-snapshot',
            'artifact_id': bundle['artifact_id'], 'artifact_manifest_sha256': digest(artifact/'manifest.json'),
            'source_manifest_sha256': manifest_sha256, 'source_entries_verified': len(source_manifest['files']),
            'archived_proof_pins_sha256': digest(pins_path),
            'original_proof_candidate': pins['artifact_id'], 'new_followups': results,
            'full_notice_location_followups_including_addendum': len(located),
            'baseline_records_without_full_notice_followup': len(audit['issues'])-len(located),
            'active_build_receipt_used': False, 'active_cargo_cache_used': False,
            'original_reports_modified': False, 'new_binary_package_needed_for_notice_bytes': False,
            'source_archive_bytes_verified': False, 'fresh_full_build_verified': False,
            'complete_license_source_audit': False}


def verify(artifact):
    pins_path = ROOT/'Linux/native-published-notices.json'
    pins = json.loads(pins_path.read_text())
    audit_path = ROOT/'Build/Linux/source-audit'/('native-source-audit-'+pins['baseline_audit_sha256'][:24])/'report.json'
    if digest(audit_path) != pins['baseline_audit_sha256']:
        raise ValueError('Original notice inventory differs')
    audit = json.loads(audit_path.read_text())
    packages = {p['id']: p for p in audit['cargo_packages']}
    existing = json.loads((ROOT/'Linux/native-notice-supplements.json').read_text())
    if digest(ROOT/'Linux/native-notice-supplements.json') != pins['existing_supplement_pins_sha256']:
        raise ValueError('Existing followup baseline differs')
    already_located = {p['package_id'] for p in existing['packages'] if p['full_package_notice_located']}
    receipt = native_receipt.verify(ROOT/'Build/Linux/native-build.json')
    artifact = Path(artifact).resolve(strict=True)
    if not artifact.is_relative_to(ROOT/'Build/Linux/artifacts'):
        raise ValueError('Expected a local generated artifact')
    manifest = native_bundle.verify(artifact)
    build = json.loads((artifact/'build.json').read_text())
    if manifest['artifact_id'] != pins['artifact_id'] or build['build_receipt']['sources'] != receipt['sources']:
        raise ValueError('Published notice proof refers to a different candidate')
    snapshot = ROOT/'Build/Linux/source-bundles'/native_bundle.relative_path(pins['source_snapshot'])
    if (digest(snapshot/'source-manifest.json') != pins['source_manifest_sha256']
            or digest(snapshot.with_suffix('.tar.gz')) != pins['source_archive_sha256']):
        raise ValueError('Delivered source snapshot identity differs')
    source_manifest = json.loads((snapshot/'source-manifest.json').read_text())
    results = []
    for pin in pins['packages']:
        package = packages[pin['package_id']]
        if package['name'] != pin['name'] or package['version'] != pin['version']:
            raise ValueError('Published package identity differs')
        root = (ROOT/package['source_root']).resolve(strict=True)
        if not root.is_relative_to(ROOT/'Build/Linux/cargo/registry/src'):
            raise ValueError('Expected a published Cargo registry source')
        tree_path = ROOT/native_bundle.relative_path(pin['tree_path'])
        if tree_path.is_symlink() or digest(tree_path) != pin['tree_sha256']:
            raise ValueError('Pinned upstream tree differs')
        tree = json.loads(tree_path.read_text())
        count = verify_crate(root, pin, tree)
        for entry in pin['published_files']:
            name = str(native_bundle.relative_path(pin['source_snapshot_package']) /
                       native_bundle.relative_path(entry['local_path']))
            if (source_manifest['files'][name]['sha256'] != entry['sha256']
                    or digest(snapshot/name) != entry['sha256']):
                raise ValueError('Published source is missing or differs in delivered source snapshot')
        notice = pin['notice']
        entry = audit['materials'][notice['existing_material']]
        local = audit_path.parent/'materials'/native_bundle.relative_path(notice['existing_material'])
        shipped = artifact/'licenses/dependencies/inventory/materials'/notice['existing_material']
        data = local.read_bytes()
        node = next(n for n in tree['tree'] if n['path'] == notice['upstream_path'] and n['type'] == 'blob')
        expected_url = f'https://raw.githubusercontent.com/{pin["repository"]}/{pin["revision"]}/{notice["upstream_path"]}'
        if (notice['url'] != expected_url or node['mode'] != '100644'
                or notice['git_blob_sha1'] != node['sha'] or blob(data) != node['sha']
                or len(data) != node['size'] or notice['bytes'] != len(data)
                or entry != {'bytes': len(data), 'sha256': digest(local)}
                or notice['sha256'] != digest(local) or shipped.read_bytes() != data):
            raise ValueError('Existing/shipped notice differs from the pinned upstream text')
        if (pin['package_id'] in already_located or
                {'package': pin['package_id'], 'kind': 'no_matching_package_or_ancestor_notice_file'} not in audit['issues']):
            raise ValueError('Followup does not correspond to an unresolved notice location')
        results.append({'package_id': pin['package_id'], 'published_files_verified': count,
                        'upstream_commit': pin['revision'], 'notice_sha256': digest(local),
                        'existing_material': notice['existing_material'], 'already_in_candidate': True,
                        'all_published_sources_already_delivered': True})
    if len({r['package_id'] for r in results}) != len(results):
        raise ValueError('Duplicate published notice followup')
    total = len(already_located) + len(results)
    return {'schema': 1, 'result': 'pass', 'artifact_id': manifest['artifact_id'],
            'pins_sha256': digest(pins_path), 'baseline_audit_sha256': digest(audit_path),
            'source_archive_sha256': pins['source_archive_sha256'],
            'new_followups': results, 'full_notice_location_followups_including_addendum': total,
            'baseline_records_without_full_notice_followup': len(audit['issues'])-total,
            'original_reports_modified': False, 'new_binary_package_needed_for_notice_bytes': False,
            'complete_license_source_audit': False}
