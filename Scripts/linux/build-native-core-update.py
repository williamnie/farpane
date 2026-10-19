#!/usr/bin/env python3
"""Build a core-only patch update against a verified frozen candidate.

The generated checkout is copied, never edited: canonical patches newer than
the frozen parent (including paused drafts) are reversed in the copy, the
parent's overlays are restored, and only the selected new patches are applied.
GUI, FFmpeg and dependency locks are reused. Output stays under Build/Linux.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Linux/packaging'))
import native_bundle as bundle

CHECKOUT = ROOT / 'Build/Linux/src/rustdesk'
CACHE = ROOT / 'Build/Linux/core-update-target'
FEATURES = ['--no-default-features', '--features', 'farpane-native,linux-gpu-media']


def git_apply(tree, patch, reverse=False):
    command = ['git', '-C', str(tree), 'apply'] + (['--reverse'] if reverse else [])
    env = {**os.environ, 'GIT_CEILING_DIRECTORIES': str(tree.parent)}
    subprocess.run(command + ['--check', str(patch)], env=env, check=True)
    subprocess.run(command + [str(patch)], env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('base', type=Path)
    parser.add_argument('--patch', action='append', required=True,
                        help='Canonical Linux/patches file to apply on the parent (repeatable)')
    parser.add_argument('--test-filter', action='append', default=[],
                        help='cargo test --lib filter run before the release build (repeatable)')
    args = parser.parse_args()
    base = args.base.resolve(strict=True)
    if os.getuid() == 0 or base.parent != ROOT / 'Build/Linux/artifacts':
        raise ValueError('Use an existing frozen artifact as an ordinary user')
    manifest = bundle.verify(base)
    build = json.loads((base / 'build.json').read_text())
    if build.get('core_update'):
        raise ValueError('Use a parent whose core came from a recorded full build')
    for name, sha in build['build_receipt']['sources'].items():
        path = base / ('dependencies.lock.json' if name == 'Linux/dependencies.lock.json' else 'source/' + name)
        if bundle.digest(path) != sha:
            raise ValueError('Frozen compiled source changed: ' + name)
    parent_lock = json.loads((base / 'dependencies.lock.json').read_text())
    active_lock = json.loads((ROOT / 'Linux/dependencies.lock.json').read_text())
    parent_patches = [e['path'] for e in parent_lock['patches']]
    active_patches = [e['path'] for e in active_lock['patches']]
    if active_patches[:len(parent_patches)] != parent_patches:
        raise ValueError('Active patch series does not extend the frozen parent')
    later = active_patches[len(parent_patches):]
    selected = [str((ROOT / p).resolve(strict=True).relative_to(ROOT)) for p in args.patch]
    if any(p not in later for p in selected):
        raise ValueError('Selected patches must be canonical and newer than the parent')
    for key in ('rustdesk', 'hbb_common', 'lockfiles'):
        if parent_lock[key] != active_lock[key]:
            raise ValueError('Upstream pins or Cargo locks differ from the parent: ' + key)
    entries = {e['path']: e for e in active_lock['patches']}
    for path in later:
        if bundle.digest(ROOT / path) != entries[path]['sha256']:
            raise ValueError('Canonical patch differs from its lock entry: ' + path)

    parent = ROOT / 'Build/Linux/core-updates'
    parent.mkdir(exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    print(output, flush=True)
    tree = output / 'rustdesk'
    shutil.copytree(CHECKOUT, tree, symlinks=True)
    for path in reversed(later):
        git_apply(tree, ROOT / path, reverse=True)
    parent_overlays = {e['target']: e for e in parent_lock['overlays']}
    for entry in active_lock['overlays']:
        if entry['target'] not in parent_overlays:
            (tree / entry['target']).unlink()
    for target, entry in parent_overlays.items():
        shutil.copyfile(base / 'source' / entry['path'], tree / target)
        if bundle.digest(tree / target) != entry['sha256']:
            raise ValueError('Parent overlay differs: ' + target)
    for path in selected:
        git_apply(tree, ROOT / path)
    lock = json.loads(json.dumps(parent_lock))
    lock['patches'] += [entries[p] for p in selected]
    (output / 'dependencies.lock.json').write_text(json.dumps(lock, indent=2) + '\n')
    for path in selected:
        destination = output / 'source' / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / path, destination)
    shutil.copyfile(Path(__file__), output / Path(__file__).name)

    if not CACHE.exists():
        # Seed once from the product cache; later runs never write the original.
        subprocess.run(['cp', '-a', str(ROOT / 'Build/Linux/target'), str(CACHE)], check=True)
    image = active_lock['builder']['image']
    command = ['docker', 'run', '--rm', '--network', 'none', '--cpus', '4', '--memory', '12g',
        '--pids-limit', '512', '--user', f'{os.getuid()}:{os.getgid()}',
        '--mount', f'type=bind,src={ROOT},dst=/workspace,readonly',
        '--mount', f'type=bind,src={ROOT}/Build/Linux,dst=/workspace/Build/Linux',
        '--mount', f'type=bind,src={tree},dst=/workspace/Build/Linux/src/rustdesk',
        '--mount', f'type=bind,src={CACHE},dst=/workspace/Build/Linux/target',
        '-e', 'CARGO_HOME=/workspace/Build/Linux/cargo', '-e', 'CARGO_TARGET_DIR=/workspace/Build/Linux/target',
        '-e', 'VCPKG_ROOT=/workspace/Build/Linux/vcpkg', '-e', 'CARGO_BUILD_JOBS=4',
        '-e', 'CXXFLAGS=-include cstdint',
        '-e', 'PATH=/workspace/Build/Linux/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        '--workdir', '/workspace/Build/Linux/src/rustdesk',
        '--entrypoint', '/workspace/Build/Linux/toolchain/bin/cargo', image]
    receipt = {'schema': 1, 'base_artifact': base.name,
        'base_manifest_sha256': bundle.digest(base / 'manifest.json'),
        'base_build_sha256': bundle.digest(base / 'build.json'), 'builder': active_lock['builder'],
        'reversed_in_copy': later, 'applied_patches': selected,
        'sources': {'Linux/dependencies.lock.json': bundle.digest(output / 'dependencies.lock.json'),
                    **{p: entries[p]['sha256'] for p in selected}},
        'recipe_sha256': bundle.digest(Path(__file__)), 'commands': [],
        'gui_rebuilt': False, 'media_rebuilt': False, 'offline': True, 'locked': True}
    (output / 'inputs.json').write_text(json.dumps(receipt, indent=2) + '\n')
    phases = [('test-' + str(i), ['test', '--offline', '--locked', *FEATURES, '--lib', f])
              for i, f in enumerate(args.test_filter)]
    phases.append(('release', ['build', '--offline', '--locked', '--release', *FEATURES, '--bin', 'farpane-core']))
    for phase, arguments in phases:
        with (output / (phase + '.log')).open('w') as log:
            result = subprocess.run(command + arguments, stdout=log, stderr=subprocess.STDOUT, timeout=5400)
        receipt['commands'].append({'phase': phase, 'command': command + arguments,
            'returncode': result.returncode, 'log_sha256': bundle.digest(output / (phase + '.log'))})
        (output / 'progress.json').write_text(json.dumps(receipt, indent=2) + '\n')
        if result.returncode:
            raise SystemExit(f'{phase} failed; see {output}')
    executable = output / 'farpane-core'
    shutil.copy2(CACHE / 'release/farpane-core', executable)
    if bundle.verify(base) != manifest:
        raise ValueError('Frozen parent changed during core compilation')
    for path in selected:
        if bundle.digest(ROOT / path) != entries[path]['sha256']:
            raise ValueError('Canonical patch changed during compilation: ' + path)
    receipt['binary_sha256'] = bundle.digest(executable)
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'result': 'pass', 'output': str(output),
                      'binary_sha256': receipt['binary_sha256'], 'patches': selected}), flush=True)


if __name__ == '__main__':
    main()
