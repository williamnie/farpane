#!/usr/bin/env python3
"""Add a verified GUI build to an existing core-update test candidate.

This preserves the older GUI/core receipts and their exact parent manifests.
Dependency notices already marked as unrebound by the core update stay explicitly
unrebound. It never relaxes the normal publication/source-audit verifier.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Linux/packaging'))
import native_bundle as bundle


def read(path):
    return json.loads(path.read_text())


def gui_delta(parent_sources, compiled):
    """The compiled protocol, assets, bridges and Cargo inputs must be identical."""
    expected = {k: v for k, v in parent_sources.items()
                if k.startswith(('Linux/gui/', 'Linux/native/protocol/'))}
    if expected.keys() != compiled.keys():
        raise ValueError('GUI compilation input inventory differs')
    changed = sorted(k for k in expected if expected[k] != compiled[k])
    if not changed or any(not k.startswith('Linux/gui/src/') or not k.endswith('.rs') for k in changed):
        raise ValueError('Only existing GUI Rust files may differ')
    return changed


def package(base, update, version):
    base, update = base.resolve(strict=True), update.resolve(strict=True)
    if (base.parent != ROOT / 'Build/Linux/artifacts'
            or update.parent != ROOT / 'Build/Linux/gui-updates'
            or not re.fullmatch(r'\d+\.\d+\.\d+-dev\.\d{8}\.\d+', version)):
        raise ValueError('Expected a frozen base, recorded GUI build and development version')
    original = bundle.verify(base)
    build = read(base / 'build.json')
    # This path is only for the already-disclosed private core candidate. Do not
    # silently turn a fully bound delivery into one with weaker provenance.
    if (build.get('gui_layer') or not build.get('core_update')
            or build['core_update'].get('notice_source_map_rebound') is not False):
        raise ValueError('Expected one existing unrebound core-update test candidate')
    receipt = read(update / 'receipt.json')
    compilation_base_name = receipt['base_artifact']
    if not re.fullmatch(r'farpane-native-dev-[0-9a-f]{24}', compilation_base_name):
        raise ValueError('Unexpected GUI compilation baseline name')
    compilation_base = base.parent / compilation_base_name
    bundle.verify(compilation_base)
    if (receipt['base_manifest_sha256'] != bundle.digest(compilation_base / 'manifest.json')
            or receipt['base_build_sha256'] != bundle.digest(compilation_base / 'build.json')
            or receipt['binary_sha256'] != bundle.digest(update / 'farpane')
            or receipt['recipe_sha256'] != bundle.digest(update / 'build-native-gui-update.py')
            or receipt['core_rebuilt'] is not False or receipt['media_rebuilt'] is not False
            or receipt['offline'] is not True or receipt['locked'] is not True
            or [c['phase'] for c in receipt['commands']] != ['test', 'release']):
        raise ValueError('GUI executable or build provenance differs')
    for command in receipt['commands']:
        if command['returncode'] or command['log_sha256'] != bundle.digest(update / (command['phase'] + '.log')):
            raise ValueError('GUI build did not pass its recorded commands')
    actual = {str(p.relative_to(update / 'source')): bundle.digest(p)
              for p in (update / 'source').rglob('*') if p.is_file()}
    if actual != receipt['sources']:
        raise ValueError('Compiled GUI inputs changed')
    compiled_parent = read(compilation_base / 'build.json')['build_receipt']['sources']
    original_changes = gui_delta(compiled_parent, actual)
    if [k.removeprefix('Linux/gui/') for k in original_changes] != receipt['changed_gui_sources']:
        raise ValueError('GUI build source delta differs')
    sources = dict(build['build_receipt']['sources'])
    for name, sha in sources.items():
        path = base / ('dependencies.lock.json' if name == 'Linux/dependencies.lock.json' else 'source/' + name)
        if bundle.digest(path) != sha:
            raise ValueError('Parent source differs: ' + name)
    changed = gui_delta(sources, actual)
    spec = importlib.util.spec_from_file_location('native_packager', ROOT / 'Scripts/linux/package-native.py')
    packer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packer)
    with tempfile.TemporaryDirectory(prefix='.native-gui-layer-', dir=base.parent) as temporary:
        staged = Path(temporary) / 'bundle'
        shutil.copytree(base, staged, symlinks=True)
        (staged / 'manifest.json').unlink()
        shutil.copy2(update / 'farpane', staged / 'farpane')
        subprocess.run(['patchelf', '--remove-rpath', str(staged / 'farpane')], check=True)
        report = packer.elf_report(staged / 'farpane')
        if report['needed'] != build['packaged_binaries']['farpane']['needed']:
            raise ValueError('GUI dynamic dependencies changed')
        for name in changed:
            shutil.copy2(update / 'source' / name, staged / 'source' / name)
            sources[name] = actual[name]
        proof = staged / 'source/gui-layer'
        proof.mkdir()
        for name in ['receipt.json', 'inputs.json', 'test.log', 'release.log', 'build-native-gui-update.py']:
            shutil.copy2(update / name, proof / name)
        shutil.copy2(base / 'build.json', proof / 'parent-build.json')
        shutil.copy2(base / 'manifest.json', proof / 'parent-manifest.json')
        shutil.copy2(Path(__file__), staged / 'source/Scripts/linux/repackage-native-gui-layer.py')
        core_sha = build['packaged_binaries']['libexec/farpane-core']['sha256']
        (staged / 'release-info.json').write_text(json.dumps({
            'schema': 1, 'version': version, 'core_sha256': core_sha}, indent=2) + '\n')
        build['gui_layer'] = {'schema': 1, 'parent_artifact': base.name,
            'parent_manifest_sha256': bundle.digest(base / 'manifest.json'),
            'parent_build_sha256': bundle.digest(base / 'build.json'),
            'build_receipt_sha256': bundle.digest(proof / 'receipt.json'),
            'recipe_sha256': bundle.digest(Path(__file__)), 'version': version,
            'changed_sources': changed, 'core_rebuilt': False, 'media_rebuilt': False,
            'notice_source_map_rebound': False, 'full_source_archive_updated': False}
        build['build_receipt']['sources'] = sources
        build['build_receipt']['binaries']['native-gui'] = receipt['binary_sha256']
        build['build_receipt']['incremental_gui_layer'] = build['gui_layer']
        build['packaged_binaries']['farpane'] = report
        build['input_binaries']['farpane'] = receipt['binary_sha256']
        (staged / 'build.json').write_text(json.dumps(build, indent=2) + '\n')
        with (staged / 'README.txt').open('a') as output:
            output.write('Visible-version GUI layer: see build.json gui_layer and source/gui-layer.\n'
                         'Core/media unchanged. Existing unbound notice/source gates remain open.\n')
        for name, value in build['packaged_binaries'].items():
            if bundle.digest(staged / name) != value['sha256']:
                raise ValueError('Packaged binary differs: ' + name)
            if name != 'farpane' and bundle.digest(staged / name) != bundle.digest(base / name):
                raise ValueError('Core/media changed')
        for name, sha in sources.items():
            path = staged / ('dependencies.lock.json' if name == 'Linux/dependencies.lock.json' else 'source/' + name)
            if bundle.digest(path) != sha:
                raise ValueError('Packaged source differs: ' + name)
        for path in (staged / 'licenses').rglob('*'):
            if path.is_file() and bundle.digest(path) != bundle.digest(base / path.relative_to(staged)):
                raise ValueError('Frozen dependency materials changed')
        for path in staged.rglob('*'):
            if path.is_dir():
                path.chmod(0o755)
            elif path.is_file() and not path.is_symlink():
                path.chmod(0o755 if path.stat().st_mode & 0o111 else 0o644)
        manifest = bundle.seal(staged)
        target = base.parent / manifest['artifact_id']
        if target.exists():
            if bundle.verify(target) != manifest:
                raise ValueError('Refusing to overwrite an artifact')
        else:
            staged.rename(target)
        bundle.verify(target)
        if bundle.verify(base) != original:
            raise ValueError('Parent changed during packaging')
        return {'artifact': str(target), 'version': version, 'gui_sha256': report['sha256'],
                'core_sha256': core_sha, 'changed_sources': changed, 'installed': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('base', type=Path)
    parser.add_argument('update', type=Path)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    print(json.dumps(package(args.base, args.update, args.version), indent=2))
