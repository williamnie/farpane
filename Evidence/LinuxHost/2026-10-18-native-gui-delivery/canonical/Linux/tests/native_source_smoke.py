"""Resolve and compile an extracted source snapshot without repository/cache mounts."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile

assert Path('/.dockerenv').is_file() and os.geteuid() != 0
assert not Path('/dev/dri').exists()
output = Path('/output')
archive = Path('/inputs/source.tar.gz')
assert Path(os.environ['CARGO_HOME']) == output / 'cargo-home'
assert Path(os.environ['CARGO_TARGET_DIR']) == output / 'target'
assert not (output / 'cargo-home').exists() and not (output / 'target').exists()


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


assert digest(archive) == sys.argv[1], 'Source archive checksum mismatch'
print('Extracting checksum-verified source archive', flush=True)
with tarfile.open(archive) as stream:
    members = stream.getmembers()
    roots = {Path(member.name).parts[0] for member in members}
    assert len(roots) == 1 and next(iter(roots)).startswith('farpane-native-source-')
    assert sum(member.size for member in members) <= 10 * 1024**3
    stream.extractall(output, filter='data')
snapshot = output / roots.pop()
manifest = json.loads((snapshot / 'source-manifest.json').read_text())
assert manifest['schema'] == 1 and manifest['kind'] == 'farpane-native-source-snapshot'
print('Verifying every extracted source entry', flush=True)
files = {}
for path in snapshot.rglob('*'):
    name = path.relative_to(snapshot).as_posix()
    if name == 'source-manifest.json':
        continue
    mode = path.lstat().st_mode
    if stat.S_ISREG(mode):
        files[name] = {'sha256': digest(path), 'bytes': path.stat().st_size,
                       'executable': bool(mode & 0o111)}
    elif stat.S_ISLNK(mode):
        assert not path.readlink().is_absolute() and path.resolve(strict=True).is_relative_to(snapshot)
        files[name] = {'symlink': str(path.readlink())}
    else:
        assert stat.S_ISDIR(mode)
assert files == manifest['files'], 'Extracted source inventory/hash mismatch'
checks = ['archive_sha256_and_complete_extracted_source_manifest']
if manifest.get('gui_source_update'):
    update = manifest['gui_source_update']
    receipt = json.loads((snapshot/'binary-build-receipt.json').read_text())
    build = json.loads((snapshot/'gui-update/artifact-build.json').read_text())
    assert digest(snapshot/'gui-update/artifact-build.json') == update['artifact_build_sha256']
    assert receipt == build['build_receipt']
    for name, sha in receipt['sources'].items():
        assert files[name]['sha256'] == sha
    staged = json.loads((snapshot/'Build/Linux/native-source-map.json').read_text())
    for name, sha in staged.items():
        assert files['Linux/'+name]['sha256'] == sha
        assert files['Build/Linux/'+name]['sha256'] == sha
    checks.append('gui_candidate_receipt_canonical_and_prepared_sources_match')


def cargo(name, *args):
    print('Running offline Cargo ' + name, flush=True)
    with (output / (name + '.stdout')).open('w') as stdout, (output / (name + '.stderr')).open('w') as stderr:
        result = subprocess.run(['/toolchain/bin/cargo', *args], cwd=snapshot, stdout=stdout,
                                stderr=stderr, timeout=600)
    assert result.returncode == 0, (name, result.returncode)


graphs = {}
for component, relative, extra in [
    ('core', 'Build/Linux/src/rustdesk/Cargo.toml',
     ['--no-default-features', '--features', 'farpane-native,linux-gpu-media']),
    ('gui', 'Build/Linux/gui/Cargo.toml', []),
]:
    cargo(component + '-metadata', 'metadata', '--offline', '--locked', '--filter-platform',
          'x86_64-unknown-linux-gnu', '--manifest-path', relative, '--format-version', '1', *extra)
    data = json.loads((output / (component + '-metadata.stdout')).read_text())
    assert all(Path(p['manifest_path']).is_relative_to(snapshot) for p in data['packages'])
    graphs[component] = len(data['packages'])
    checks.append('empty_cargo_home_offline_' + component + '_graph_inside_snapshot')
if sys.argv[2:] == ['--metadata-only']:
    result = {'result':'pass','checks':checks,'archive_sha256':sys.argv[1],
              'source_entries':len(files),'cargo_graph_packages':graphs,
              'repository_mounted':False,'compiler_cache_mounted':False,'network':'none',
              'full_gui_release_build':False,'full_native_media_build':False,
              'complete_license_source_audit':False,'host_modified':False}
    (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result),flush=True)
    raise SystemExit(0)
assert len(sys.argv) == 2, 'Unexpected source test arguments'
cargo('protocol-tests', 'test', '--offline', '--locked', '--manifest-path',
      'Build/Linux/gui/Cargo.toml', '-p', 'farpane-protocol', '--lib')
assert '38 passed; 0 failed' in (output / 'protocol-tests.stdout').read_text()
checks.append('fresh_target_compilation_and_38_actual_protocol_tests')
cargo('gui-release', 'build', '--offline', '--locked', '--release', '--manifest-path',
      'Build/Linux/gui/Cargo.toml')
gui = output / 'target/release/farpane'
probe = subprocess.run([str(gui), '--build-info'], capture_output=True, text=True, timeout=15)
assert probe.returncode == 0, probe.stderr
info = json.loads(probe.stdout)
assert info['component'] == 'native-gui' and info['product'] == 'FarPane'
assert info['protocol'] == 1 and info['gtk_minimum'] == '4.14' and info['libadwaita_minimum'] == '1.5'
assert info['runtime_ready'] is False
(output / 'gui-build-info.json').write_text(json.dumps(info, indent=2) + '\n')
checks.append('offline_full_gui_release_build_and_headless_component_probe')
assert not (output / 'cargo-home/registry').exists()
assert not (output / 'cargo-home/git').exists()
result = {'result': 'pass', 'checks': checks, 'archive_sha256': sys.argv[1],
          'source_entries': len(files), 'cargo_graph_packages': graphs,
          'gui_sha256': digest(gui), 'full_gui_release_build': True,
          'compiler': subprocess.check_output(['/toolchain/bin/rustc', '--version'], text=True).strip(),
          'rust_sdk': {'rustc_sha256': digest(Path('/toolchain/bin/rustc')),
                       'cargo_sha256': digest(Path('/toolchain/bin/cargo')),
                       'receipt_sha256': digest(Path('/toolchain/toolchain-receipt.json'))
                       if Path('/toolchain/toolchain-receipt.json').is_file() else None},
          'repository_mounted': False, 'compiler_cache_mounted': False,
          'network': 'none', 'full_native_media_build': False,
          'complete_license_source_audit': False, 'host_modified': False}
(output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result), flush=True)
