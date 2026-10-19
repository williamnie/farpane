#!/usr/bin/env python3
"""Compose a verified GUI-only build with frozen core/media and dependency materials."""
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
import native_notice_delivery as notices


def read(path):
    return json.loads(path.read_text())


def package(base, update):
    base, update = base.resolve(strict=True), update.resolve(strict=True)
    if (base.parent != ROOT / 'Build/Linux/artifacts'
            or update.parent != ROOT / 'Build/Linux/gui-updates'):
        raise ValueError('Expected frozen bundle and isolated GUI build under Build/Linux')
    original = bundle.verify(base)
    build = read(base / 'build.json')
    receipt = read(update / 'receipt.json')
    if (build.get('gui_update') or receipt['base_artifact'] != base.name
            or receipt['base_manifest_sha256'] != bundle.digest(base / 'manifest.json')
            or receipt['base_build_sha256'] != bundle.digest(base / 'build.json')
            or receipt['core_rebuilt'] is not False or receipt['media_rebuilt'] is not False
            or receipt['offline'] is not True or receipt['locked'] is not True):
        raise ValueError('GUI build does not match the frozen parent')
    if (receipt['binary_sha256'] != bundle.digest(update / 'farpane')
            or receipt['recipe_sha256'] != bundle.digest(update / 'build-native-gui-update.py')
            or [c['phase'] for c in receipt['commands']] != ['test', 'release']):
        raise ValueError('GUI executable or build recipe differs')
    for command in receipt['commands']:
        if command['returncode'] or command['log_sha256'] != bundle.digest(update / (command['phase']+'.log')):
            raise ValueError('GUI build did not pass its recorded commands')
    sources = dict(build['build_receipt']['sources'])
    actual = {str(p.relative_to(update / 'source')): bundle.digest(p)
              for p in (update / 'source').rglob('*') if p.is_file()}
    if actual != receipt['sources']:
        raise ValueError('Compiled GUI input inventory changed')
    for name, sha in sources.items():
        path = base / ('dependencies.lock.json' if name == 'Linux/dependencies.lock.json' else 'source/'+name)
        if bundle.digest(path) != sha:
            raise ValueError('Parent compiled source differs: '+name)
    changed = []
    for name, sha in actual.items():
        if name not in sources:
            raise ValueError('GUI update added an untracked compilation input: '+name)
        if sources[name] != sha:
            changed.append(name)
            sources[name] = sha
    notices.gui_source_baseline(sources, {'schema': 1, 'base_sources': build['build_receipt']['sources'],
                                         'changed_sources': sorted(changed)})
    if sorted(k.removeprefix('Linux/gui/') for k in changed) != receipt['changed_gui_sources']:
        raise ValueError('GUI source delta differs from build receipt')
    spec = importlib.util.spec_from_file_location('package_native', ROOT/'Scripts/linux/package-native.py')
    packer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packer)
    with tempfile.TemporaryDirectory(prefix='.native-gui-', dir=base.parent) as temp:
        staged = Path(temp) / 'bundle'
        shutil.copytree(base, staged, symlinks=True)
        (staged/'manifest.json').unlink()
        shutil.copy2(update/'farpane', staged/'farpane')
        subprocess.run(['patchelf','--remove-rpath',str(staged/'farpane')],check=True)
        build['packaged_binaries']['farpane'] = packer.elf_report(staged/'farpane')
        build['input_binaries']['farpane'] = receipt['binary_sha256']
        for name in changed:
            shutil.copy2(update/'source'/name, staged/'source'/name)
        proof = staged/'source/gui-update'
        proof.mkdir()
        for name in ('receipt.json', 'inputs.json', 'test.log', 'release.log', 'build-native-gui-update.py'):
            shutil.copy2(update/name, proof/name)
        for name in ('Scripts/linux/repackage-native-gui.py', 'Linux/packaging/native_notice_delivery.py'):
            shutil.copy2(ROOT/name, staged/'source'/name)
        build['gui_update'] = {'schema': 1, 'parent_artifact': base.name,
            'parent_manifest_sha256': bundle.digest(base/'manifest.json'),
            'parent_build_sha256': bundle.digest(base/'build.json'),
            'build_receipt_sha256': bundle.digest(proof/'receipt.json'),
            'recipe_sha256': bundle.digest(Path(__file__)), 'changed_sources': sorted(changed),
            'core_rebuilt': False, 'media_rebuilt': False,
            'full_source_archive_updated': False}
        build['build_receipt']['sources'] = sources
        build['build_receipt']['binaries']['native-gui'] = receipt['binary_sha256']
        build['build_receipt']['incremental_gui_update'] = build['gui_update']
        pins = bundle.digest(staged/'source/Linux/native-notice-supplements.json')
        notices.rebind_gui_sources(staged/'licenses/dependencies', sources, pins)
        build['notice_delivery_manifest_sha256'] = bundle.digest(staged/'licenses/dependencies/manifest.json')
        (staged/'build.json').write_text(json.dumps(build,indent=2)+'\n')
        with (staged/'README.txt').open('a') as out:
            out.write('GUI-only Rust source update: see build.json gui_update and source/gui-update.\n'
                      'Core/media and all dependency inputs reused from the recorded frozen parent.\n'
                      'The parent complete source archive requires this GUI source/build supplement.\n')
        for name, item in build['packaged_binaries'].items():
            if bundle.digest(staged/name) != item['sha256']:
                raise ValueError('Packaged binary differs: '+name)
            if name != 'farpane' and bundle.digest(staged/name) != bundle.digest(base/name):
                raise ValueError('Non-GUI binary changed')
        for name, sha in sources.items():
            path = staged/('dependencies.lock.json' if name == 'Linux/dependencies.lock.json' else 'source/'+name)
            if bundle.digest(path) != sha:
                raise ValueError('Packaged source differs: '+name)
        for path in staged.rglob('*'):
            if path.is_dir():
                path.chmod(0o755)
            elif path.is_file() and not path.is_symlink():
                path.chmod(0o755 if path.stat().st_mode & 0o111 else 0o644)
        manifest = bundle.seal(staged)
        output = base.parent/manifest['artifact_id']
        if output.exists():
            if bundle.verify(output) != manifest:
                raise ValueError('Refusing to overwrite artifact')
        else:
            staged.rename(output)
        bundle.verify(output)
        if bundle.verify(base) != original:
            raise ValueError('Parent changed during GUI packaging')
        return {'artifact': str(output), 'manifest_sha256': bundle.digest(output/'manifest.json'),
                'gui_sha256': build['packaged_binaries']['farpane']['sha256'],
                'changed_sources': changed, 'installed': False, 'runtime_ready': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('base', type=Path)
    parser.add_argument('update', type=Path)
    args = parser.parse_args()
    print(json.dumps(package(args.base,args.update),indent=2))
