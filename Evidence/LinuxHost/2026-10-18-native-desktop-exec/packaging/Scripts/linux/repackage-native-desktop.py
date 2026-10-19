#!/usr/bin/env python3
"""Apply the canonical desktop Exec launch change to a frozen native bundle.

No compilation, installation or application launch. Preserve the compiled
source receipt and all binaries; record the exact parent and packaging delta.
"""
import argparse
import json
from pathlib import Path
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / 'Build/Linux/artifacts'
sys.path.insert(0, str(ROOT / 'Linux/packaging'))
import native_bundle

TEMPLATE = 'Linux/packaging/org.farpane.FarPane.desktop.in'
DESKTOP = 'share/applications/org.farpane.FarPane.desktop'
RECIPE = 'Scripts/linux/repackage-native-desktop.py'


def package(base):
    base = base.resolve(strict=True)
    if not base.is_relative_to(ARTIFACTS) or ARTIFACTS.is_symlink():
        raise ValueError('Expected an existing bundle under Build/Linux/artifacts')
    before = native_bundle.verify(base)
    if base.name != before['artifact_id']:
        raise ValueError('Parent directory does not match its verified identity')
    build = json.loads((base / 'build.json').read_text())
    if build.get('desktop_repackage'):
        raise ValueError('Use the original compiled bundle, not a packaging derivative')
    for name, sha in build['build_receipt']['sources'].items():
        name = native_bundle.relative_path(name)
        path = base / ('dependencies.lock.json' if str(name) == 'Linux/dependencies.lock.json'
                       else 'source/' + str(name))
        if native_bundle.digest(path) != sha:
            raise ValueError('Parent compiled source differs from its receipt: ' + str(name))
    for name, record in build['packaged_binaries'].items():
        if native_bundle.digest(base / native_bundle.relative_path(name)) != record['sha256']:
            raise ValueError('Parent binary differs from its build record: ' + name)
    # The recipe deliberately permits one desktop key change, not replacing
    # compiled source or importing unrelated worktree edits into a frozen build.
    old = (base / DESKTOP).read_bytes()
    new = (ROOT / TEMPLATE).read_bytes()
    if (old != (base / 'source' / TEMPLATE).read_bytes()
            or old.count(b'DBusActivatable=true\n') != 1
            or new != old.replace(b'DBusActivatable=true\n', b'DBusActivatable=false\n')):
        raise ValueError('Expected only the canonical DBusActivatable true-to-false change')
    if ((ROOT / 'Linux/packaging/native_bundle.py').read_bytes()
            != (base / 'source/Linux/packaging/native_bundle.py').read_bytes()):
        raise ValueError('Bundle integrity implementation differs from the frozen source')
    provenance = {
        'schema': 1, 'parent_artifact': before['artifact_id'],
        'parent_manifest_sha256': native_bundle.digest(base / 'manifest.json'),
        'parent_build_sha256': native_bundle.digest(base / 'build.json'),
        'canonical_template': {TEMPLATE: native_bundle.digest(ROOT / TEMPLATE)},
        'recipe': {RECIPE: native_bundle.digest(ROOT / RECIPE)},
        'application_rebuilt': False,
        'preserved_binaries': {name: record['sha256'] for name, record in build['packaged_binaries'].items()},
    }
    with tempfile.TemporaryDirectory(prefix='.native-desktop-', dir=ARTIFACTS) as temp:
        staged = Path(temp) / 'bundle'
        shutil.copytree(base, staged, symlinks=True)
        (staged / 'manifest.json').unlink()
        (staged / DESKTOP).write_bytes(new)
        (staged / 'source' / TEMPLATE).write_bytes(new)
        recipe = staged / 'source' / RECIPE
        shutil.copyfile(ROOT / RECIPE, recipe)
        recipe.chmod(0o755)
        build['desktop_repackage'] = provenance
        (staged / 'build.json').write_text(json.dumps(build, indent=2) + '\n')
        previous = {row['path']: row for row in before['files']}
        after = {row['path']: row for row in native_bundle.file_index(staged)}
        changes = {name for name in previous.keys() | after.keys() if previous.get(name) != after.get(name)}
        if changes != {DESKTOP, 'source/' + TEMPLATE, 'source/' + RECIPE, 'build.json'}:
            raise ValueError('Unexpected content changed while repackaging')
        manifest = native_bundle.seal(staged)
        output = ARTIFACTS / manifest['artifact_id']
        if output.exists():
            if native_bundle.verify(output) != manifest:
                raise ValueError('Refusing to overwrite a different artifact')
        else:
            staged.rename(output)
        if native_bundle.verify(base) != before:
            raise ValueError('Parent bundle changed during repackaging')
        return {'artifact': str(output), 'artifact_id': manifest['artifact_id'],
                'manifest_sha256': native_bundle.digest(output / 'manifest.json'),
                'changed_paths': sorted(changes), 'provenance': provenance,
                'installed': False, 'runtime_ready': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    args = parser.parse_args()
    print(json.dumps(package(args.artifact), indent=2))
