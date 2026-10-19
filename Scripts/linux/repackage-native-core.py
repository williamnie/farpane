#!/usr/bin/env python3
"""Compose a verified core-only patch build with a frozen GUI/media bundle.

Only libexec/farpane-core, the dependency lock's patch list and the added patch
files change. The Cargo locks are identical to the parent, so the delivered
dependency notice materials are carried over; their source map is not rebound
and the bundle records that open gate instead of claiming a new audit.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Linux/packaging'))
import native_bundle as bundle


def read(path):
    return json.loads(path.read_text())


def package(base, update):
    base, update = base.resolve(strict=True), update.resolve(strict=True)
    if (base.parent != ROOT / 'Build/Linux/artifacts'
            or update.parent != ROOT / 'Build/Linux/core-updates'):
        raise ValueError('Expected frozen bundle and isolated core build under Build/Linux')
    original = bundle.verify(base)
    build = read(base / 'build.json')
    receipt = read(update / 'receipt.json')
    if (build.get('core_update') or receipt['base_artifact'] != base.name
            or receipt['base_manifest_sha256'] != bundle.digest(base / 'manifest.json')
            or receipt['base_build_sha256'] != bundle.digest(base / 'build.json')
            or receipt['gui_rebuilt'] is not False or receipt['media_rebuilt'] is not False
            or receipt['offline'] is not True or receipt['locked'] is not True):
        raise ValueError('Core build does not match the frozen parent')
    if (receipt['binary_sha256'] != bundle.digest(update / 'farpane-core')
            or receipt['recipe_sha256'] != bundle.digest(update / 'build-native-core-update.py')
            or [c['phase'] for c in receipt['commands']][-1] != 'release'):
        raise ValueError('Core executable or build recipe differs')
    for command in receipt['commands']:
        if command['returncode'] or command['log_sha256'] != bundle.digest(update / (command['phase'] + '.log')):
            raise ValueError('Core build did not pass its recorded commands')
    parent_lock, lock = read(base / 'dependencies.lock.json'), read(update / 'dependencies.lock.json')
    added = lock['patches'][len(parent_lock['patches']):]
    if ({k: v for k, v in lock.items() if k != 'patches'} != {k: v for k, v in parent_lock.items() if k != 'patches'}
            or lock['patches'][:len(parent_lock['patches'])] != parent_lock['patches']
            or [e['path'] for e in added] != receipt['applied_patches']):
        raise ValueError('Core update changed more than the patch series')
    sources = dict(build['build_receipt']['sources'])
    for name, sha in sources.items():
        path = base / ('dependencies.lock.json' if name == 'Linux/dependencies.lock.json' else 'source/' + name)
        if bundle.digest(path) != sha:
            raise ValueError('Parent compiled source differs: ' + name)
    for entry in added:
        if entry['path'] in sources or bundle.digest(update / 'source' / entry['path']) != entry['sha256']:
            raise ValueError('Added patch is not a new recorded input: ' + entry['path'])
        sources[entry['path']] = entry['sha256']
    sources['Linux/dependencies.lock.json'] = bundle.digest(update / 'dependencies.lock.json')
    if {k: v for k, v in sources.items() if k in receipt['sources']} != receipt['sources']:
        raise ValueError('Core source delta differs from build receipt')
    spec = importlib.util.spec_from_file_location('package_native', ROOT / 'Scripts/linux/package-native.py')
    packer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packer)
    with tempfile.TemporaryDirectory(prefix='.native-core-', dir=base.parent) as temp:
        staged = Path(temp) / 'bundle'
        shutil.copytree(base, staged, symlinks=True)
        (staged / 'manifest.json').unlink()
        core = staged / 'libexec/farpane-core'
        shutil.copy2(update / 'farpane-core', core)
        subprocess.run(['patchelf', '--remove-rpath', str(core)], check=True)
        before = build['packaged_binaries']['libexec/farpane-core']
        report = packer.elf_report(core, core=True)
        if report['needed'] != before['needed']:
            raise ValueError('Core dynamic dependencies changed')
        build['packaged_binaries']['libexec/farpane-core'] = report
        build['input_binaries']['libexec/farpane-core'] = receipt['binary_sha256']
        shutil.copy2(update / 'dependencies.lock.json', staged / 'dependencies.lock.json')
        for entry in added:
            shutil.copy2(update / 'source' / entry['path'], staged / 'source' / entry['path'])
        proof = staged / 'source/core-update'
        proof.mkdir()
        names = ['receipt.json', 'inputs.json', 'build-native-core-update.py', 'dependencies.lock.json']
        names += [c['phase'] + '.log' for c in receipt['commands']]
        for name in names:
            shutil.copy2(update / name, proof / name)
        shutil.copy2(Path(__file__), staged / 'source/Scripts/linux/repackage-native-core.py')
        shutil.copy2(ROOT / 'Scripts/linux/build-native-core-update.py',
                     staged / 'source/Scripts/linux/build-native-core-update.py')
        build['core_update'] = {'schema': 1, 'parent_artifact': base.name,
            'parent_manifest_sha256': bundle.digest(base / 'manifest.json'),
            'parent_build_sha256': bundle.digest(base / 'build.json'),
            'build_receipt_sha256': bundle.digest(proof / 'receipt.json'),
            'recipe_sha256': bundle.digest(Path(__file__)),
            'added_patches': [e['path'] for e in added], 'reversed_in_build_copy': receipt['reversed_in_copy'],
            'gui_rebuilt': False, 'media_rebuilt': False, 'cargo_locks_changed': False,
            'notice_source_map_rebound': False, 'full_source_archive_updated': False}
        build['build_receipt']['sources'] = sources
        build['build_receipt']['binaries']['native-core'] = receipt['binary_sha256']
        build['build_receipt']['incremental_core_update'] = build['core_update']
        (staged / 'build.json').write_text(json.dumps(build, indent=2) + '\n')
        with (staged / 'README.txt').open('a') as out:
            out.write('Core-only patch update: see build.json core_update and source/core-update.\n'
                      'GUI/media reused from the recorded parent; dependency notices are not rebound.\n')
        for name, item in build['packaged_binaries'].items():
            if bundle.digest(staged / name) != item['sha256']:
                raise ValueError('Packaged binary differs: ' + name)
            if name != 'libexec/farpane-core' and bundle.digest(staged / name) != bundle.digest(base / name):
                raise ValueError('Non-core binary changed')
        for name, sha in sources.items():
            path = staged / ('dependencies.lock.json' if name == 'Linux/dependencies.lock.json' else 'source/' + name)
            if bundle.digest(path) != sha:
                raise ValueError('Packaged source differs: ' + name)
        for path in staged.rglob('*'):
            if path.is_dir():
                path.chmod(0o755)
            elif path.is_file() and not path.is_symlink():
                path.chmod(0o755 if path.stat().st_mode & 0o111 else 0o644)
        manifest = bundle.seal(staged)
        output = base.parent / manifest['artifact_id']
        if output.exists():
            if bundle.verify(output) != manifest:
                raise ValueError('Refusing to overwrite artifact')
        else:
            staged.rename(output)
        bundle.verify(output)
        if bundle.verify(base) != original:
            raise ValueError('Parent changed during core packaging')
        return {'artifact': str(output), 'manifest_sha256': bundle.digest(output / 'manifest.json'),
                'core_sha256': report['sha256'], 'added_patches': [e['path'] for e in added],
                'installed': False, 'runtime_ready': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('base', type=Path)
    parser.add_argument('update', type=Path)
    args = parser.parse_args()
    print(json.dumps(package(args.base, args.update), indent=2))
