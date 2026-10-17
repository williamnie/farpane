"""One-off evidence: verify this changed source archive without another GUI build."""
import hashlib
import json
from pathlib import Path
import tarfile

root = Path('/home/user/farpane')
base = root / 'Build/Linux/source-bundles'
identity = 'farpane-native-source-3cfe49a30f85dc07724d4c67'
old = json.loads((base / 'farpane-native-source-f50df7b05089029e0781590a/source-manifest.json').read_text())
new = json.loads((base / identity / 'source-manifest.json').read_text())
archive = base / (identity + '.tar.gz')
with archive.open('rb') as stream:
    sha = hashlib.file_digest(stream, 'sha256').hexdigest()
assert archive.with_suffix('.gz.sha256').read_text().split()[0] == sha
observed = {}
with tarfile.open(archive, 'r|gz') as stream:
    for member in stream:
        relative = Path(member.name).relative_to(identity).as_posix()
        assert '..' not in Path(relative).parts
        if member.isdir():
            continue
        if relative == 'source-manifest.json':
            assert json.load(stream.extractfile(member)) == new
        elif member.isfile():
            observed[relative] = {
                'sha256': hashlib.file_digest(stream.extractfile(member), 'sha256').hexdigest(),
                'bytes': member.size, 'executable': bool(member.mode & 0o111),
            }
        elif member.issym():
            observed[relative] = {'symlink': member.linkname}
        else:
            raise AssertionError(member.name)
assert observed == new['files']
receipt = json.loads((root / 'Build/Linux/native-build.json').read_text())
assert new['binary_sha256'] == receipt['binaries']
for prefix in ['vendor/', 'Build/Linux/gui/', 'Build/Linux/native/protocol/', 'Build/Linux/native/files/']:
    assert {k: v for k, v in old['files'].items() if k.startswith(prefix)} == {
        k: v for k, v in new['files'].items() if k.startswith(prefix)
    }, prefix
changed = [k for k in sorted(old['files'].keys() | new['files'].keys())
           if old['files'].get(k) != new['files'].get(k)]
core_changes = [k for k in changed if k.startswith('Build/Linux/src/')]
assert set(core_changes) - {'Build/Linux/src/rustdesk/src/version.rs'} == {
    'Build/Linux/src/rustdesk/src/farpane_native/mod.rs',
    'Build/Linux/src/rustdesk/src/farpane_native/transport.rs',
    'Build/Linux/src/rustdesk/src/server/connection.rs',
    'Build/Linux/src/rustdesk/src/client/io_loop.rs',
}
for name in ['Linux/native/transport.rs', 'Linux/patches/0040-native-clipboard-memory.patch']:
    assert observed[name]['sha256'] == hashlib.sha256((root / name).read_bytes()).hexdigest()
result = {
    'result': 'pass', 'archive': archive.relative_to(root).as_posix(),
    'archive_bytes': archive.stat().st_size, 'archive_sha256': sha,
    'source_entries': len(observed), 'binary_sha256': new['binary_sha256'],
    'checks': ['every_archive_entry_matches_manifest', 'current_binary_receipt',
               'canonical_transport_and_patch_present', 'vendor_gui_protocol_files_unchanged',
               'only_expected_prepared_core_changes'],
    'changed_entries': changed, 'core_changes': core_changes,
    'fresh_compilation_repeated': False,
    'prior_unchanged_gui_fresh_build': 'Build/Linux/native-source-smoke/20261017T031026Z',
    'new_core_build': 'Build/Linux/gui-work/native-clipboard-memory-build.log',
    'full_native_media_build': False, 'complete_license_source_audit': False,
}
path = root / 'Build/Linux/gui-work/native-clipboard-memory-source-check.json'
path.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({k: v for k, v in result.items() if k != 'changed_entries'}))
