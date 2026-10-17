"""Package a verified source archive without a Git checkout or product caches."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile

from native_source_build import digest, inventory, require


def main():
    output = Path('/output')
    archive = Path('/inputs/source.tar.gz')
    application = Path('/inputs/application')
    require(Path('/.dockerenv').is_file() and os.geteuid() != 0, 'Use the isolated test wrapper')
    require(not Path('/dev/dri').exists(), 'No GPU is needed for packaging')
    require(digest(archive) == sys.argv[1], 'Source archive SHA-256 mismatch')
    require(digest(application / 'result.json') == sys.argv[2], 'Source build result mismatch')
    build_result = json.loads((application / 'result.json').read_text())
    require(build_result['result'] == 'pass', 'Source build is incomplete')
    print('Extracting verified source archive', flush=True)
    with tarfile.open(archive) as stream:
        entries = stream.getmembers()
        roots = {Path(entry.name).parts[0] for entry in entries}
        require(len(roots) == 1 and next(iter(roots)).startswith('farpane-native-source-'),
                'Unexpected source archive root')
        require(sum(entry.size for entry in entries) <= 10 * 1024**3, 'Source archive too large')
        stream.extractall(output, filter='data')
    source = output / roots.pop()
    manifest = json.loads((source / 'source-manifest.json').read_text())
    require(inventory(source, ('source-manifest.json',)) == manifest['files'], 'Source inventory mismatch')
    require(manifest['binary_sha256'] == build_result['binaries'], 'Source delivery is bound to other binaries')
    require(manifest['compiled_source_build']['source_build_result_sha256'] == sys.argv[2],
            'Source delivery is bound to a different source build')
    require(not (source / '.git').exists(), 'Expected an extracted source tree')
    probe = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=source, capture_output=True, text=True)
    require(probe.returncode != 0, 'An enclosing Git checkout is visible')
    print('Building bundle from archive entrypoint', flush=True)

    def run(name, arguments):
        result = subprocess.run(['python3', '-B', *arguments], cwd=source,
                                capture_output=True, text=True, timeout=300)
        (output / (name + '.stdout')).write_text(result.stdout)
        (output / (name + '.stderr')).write_text(result.stderr)
        require(result.returncode == 0, name + ' failed; see its stdout/stderr')
        start = 0 if result.stdout.startswith('{\n') else result.stdout.rindex('\n{\n') + 1
        return json.loads(result.stdout[start:])

    packaged = run('bundle', ['Scripts/linux/package-native.py', '--source-build', str(application)])
    artifact = Path(packaged['artifact'])
    sys.path.insert(0, str(source / 'Linux/packaging'))
    import native_bundle
    bundle = native_bundle.verify(artifact)
    record = json.loads((artifact / 'build.json').read_text())
    require(record['source_origin'] == {'kind': 'source-snapshot',
            'manifest_sha256': digest(source / 'source-manifest.json')}, 'Wrong packaging origin')
    require(record['source_head'] is None and record['source_dirty'] is None, 'Fictional Git provenance')
    require(record['source_build']['source_build_result_sha256'] == sys.argv[2], 'Lost source build provenance')
    require(record['build_receipt']['binaries'] == build_result['binaries'], 'Wrong executable receipt')
    require((artifact / 'licenses/THIRD_PARTY_NOTICES.md').read_bytes() ==
            (source / 'THIRD_PARTY_NOTICES.md').read_bytes(), 'Missing root notices')
    print('Building Debian candidate from archive entrypoint', flush=True)
    deb = run('deb', ['Scripts/linux/package-native-deb.py', str(artifact), '--version', sys.argv[3]])
    extracted = output / 'deb-extracted'
    subprocess.run(['dpkg-deb', '--extract', deb['package'], str(extracted)], check=True)
    payload = extracted / 'usr/lib/farpane-native-candidate/payload'
    require(native_bundle.verify(payload) == bundle, 'Debian payload differs from verified bundle')
    metadata = json.loads((extracted / 'usr/lib/farpane-native-candidate/candidate.json').read_text())
    require(metadata['artifact_id'] == bundle['artifact_id'] and metadata['version'] == sys.argv[3],
            'Wrong Debian candidate identity')
    for name, expected in metadata['installer_sources'].items():
        require(digest(extracted / 'usr/lib/farpane-native-candidate/control' / name) == expected
                == digest(source / name), 'Installer source changed: ' + name)
    result = {'result': 'pass', 'source_archive_sha256': sys.argv[1],
              'source_manifest_sha256': digest(source / 'source-manifest.json'),
              'source_build_result_sha256': sys.argv[2], 'source_entries': len(manifest['files']),
              'bundle': packaged, 'deb': deb, 'git_checkout_visible': False,
              'network': 'none', 'binaries_recompiled': False, 'host_modified': False,
              'complete_license_source_audit': False, 'runtime_ready': False}
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
