#!/usr/bin/env python3
"""Derive a complete source snapshot for a frozen GUI-only candidate, offline."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'Linux/packaging'))
import native_bundle as bundle
import native_notice_delivery as notices
from native_published_notices import verify_snapshot
from native_source_bundle import index, verify_vendor


def read(path):
    return json.loads(path.read_text())


def validate_delta(parent_receipt, build):
    """No core, dependency, ABI or original build identity may change here."""
    receipt = build['build_receipt']
    update = build.get('gui_update', {})
    baseline = parent_receipt['sources']
    changed = sorted(k for k in receipt['sources'] if baseline.get(k) != receipt['sources'][k])
    notices.gui_source_baseline(receipt['sources'], {'schema':1, 'base_sources':baseline,
                                                    'changed_sources':changed})
    if (update.get('schema') != 1 or update.get('core_rebuilt') is not False
            or update.get('media_rebuilt') is not False or update.get('changed_sources') != changed
            or receipt['binaries']['native-core'] != parent_receipt['binaries']['native-core']
            or receipt['core_features'] != parent_receipt['core_features']
            or receipt['components'] != parent_receipt['components']):
        raise ValueError('Source parent does not describe the reused core and GUI dependency baseline')
    return changed


def package(artifact, parent, expected):
    artifact, parent = artifact.resolve(strict=True), parent.resolve(strict=True)
    output = ROOT/'Build/Linux/source-bundles'
    if (os.getuid() == 0 or artifact.parent != ROOT/'Build/Linux/artifacts'
            or parent.parent != output or output.is_symlink()):
        raise ValueError('Use frozen inputs under Build/Linux as an ordinary user')
    candidate = bundle.verify(artifact)
    build = read(artifact/'build.json')
    original = read(parent/'binary-build-receipt.json')
    print('Verifying complete parent source inventory', flush=True)
    old_manifest = verify_snapshot(parent, expected, original['sources'])
    changed = validate_delta(original, build)
    receipt = build['build_receipt']
    for name, sha in receipt['sources'].items():
        bundle.relative_path(name)
        path = artifact/('dependencies.lock.json' if name == 'Linux/dependencies.lock.json' else 'source/'+name)
        if bundle.digest(path) != sha:
            raise ValueError('Candidate source differs from the completed build: '+name)
    notices.verify(artifact/'licenses/dependencies',receipt['sources'],
                   bundle.digest(artifact/'source/Linux/native-notice-supplements.json'))
    with tempfile.TemporaryDirectory(prefix='.gui-source-',dir=output) as temp:
        tree = Path(temp)/'snapshot'
        print('Copying frozen sources and dependencies into a new snapshot',flush=True)
        shutil.copytree(parent,tree,symlinks=True)
        (tree/'source-manifest.json').unlink()
        for name in changed:
            (tree/name).parent.mkdir(parents=True, exist_ok=True)
            (tree/'Build'/name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(artifact/'source'/name,tree/name)
            shutil.copy2(artifact/'source'/name,tree/'Build'/name)
        staged_map = read(tree/'Build/Linux/native-source-map.json')
        for name in changed:
            staged_map[name.removeprefix('Linux/')] = receipt['sources'][name]
        (tree/'Build/Linux/native-source-map.json').write_text(json.dumps(staged_map,indent=2)+'\n')
        for name, sha in staged_map.items():
            if bundle.digest(tree/'Build/Linux'/name) != sha or bundle.digest(tree/'Linux'/name) != sha:
                raise ValueError('Canonical and prepared native sources differ: '+name)
        (tree/'binary-build-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
        shutil.rmtree(tree/'native-dependencies/notice-delivery')
        shutil.copytree(artifact/'licenses/dependencies',tree/'native-dependencies/notice-delivery')
        # These are exact packaging/build inputs already carried by this bundle.
        for name in ('Linux/packaging/org.farpane.FarPane.desktop.in',
                     'Linux/packaging/native_notice_delivery.py',
                     'Scripts/linux/repackage-native-desktop.py','Scripts/linux/repackage-native-gui.py'):
            shutil.copy2(artifact/'source'/name,tree/name)
        shutil.copy2(artifact/'source/gui-update/build-native-gui-update.py',tree/'Scripts/linux/build-native-gui-update.py')
        shutil.copytree(artifact/'source/gui-update',tree/'gui-update')
        shutil.copy2(artifact/'build.json',tree/'gui-update/artifact-build.json')
        # Add the derivation/verification entrypoints, without importing active
        # worktree application files or the paused core patch/pin.
        tooling = ('Scripts/linux/package-native-gui-source.py',
                   'Scripts/linux/verify-published-notices.py',
                   'Scripts/linux/test-native-source.sh',
                   'Linux/tests/native_source_smoke.py',
                   'Linux/packaging/native_published_notices.py',
                   'Linux/tests/test_native_gui_source.py',
                   'Linux/tests/test_native_gui_notices.py',
                   'Linux/tests/test_native_notice_delivery.py')
        for name in tooling:
            shutil.copy2(ROOT/name,tree/name)
        (tree/'gui-update/README.md').write_text(
            '# GUI-only source update\n\n'
            'This complete snapshot includes the updated canonical and prepared GUI, the unchanged core/media sources, '
            'Cargo vendor and native dependency source archives. No binary or compiler cache is included.\n\n'
            'binary-build-receipt.json binds to the incremental GUI build and reused core. '
            'gui-update/ retains the actual GUI build recipe, logs and artifact receipt. '
            'The root source manifest records the original source parent and this candidate.\n\n'
            'The existing full source-build entrypoint can consume this snapshot. '
            'This packaging operation did not rebuild FFmpeg, core or GUI and does not claim a fresh full build. '
            'Open license/source audit items remain open.\n')
        files = index(tree)
        verified_vendor = verify_vendor(tree,files)
        for name, sha in receipt['sources'].items():
            if files[name].get('sha256') != sha:
                raise ValueError('Updated source snapshot differs from candidate: '+name)
        # Keep every original dependency/core/vendor file unchanged. All deltas
        # must be accounted for in this derivation record.
        differences = sorted(k for k in old_manifest['files'].keys() | files.keys()
                             if old_manifest['files'].get(k) != files.get(k))
        allowed = set(changed) | {'Build/'+name for name in changed} | set(tooling) | {
            'Build/Linux/native-source-map.json','binary-build-receipt.json',
            'native-dependencies/notice-delivery/manifest.json',
            'Linux/packaging/org.farpane.FarPane.desktop.in','Linux/packaging/native_notice_delivery.py',
            'Scripts/linux/repackage-native-desktop.py','Scripts/linux/repackage-native-gui.py',
            'Scripts/linux/build-native-gui-update.py'}
        if any(name not in allowed and not name.startswith('gui-update/') for name in differences):
            raise ValueError('Unaccounted source snapshot change')
        manifest = dict(old_manifest,files=files,binary_sha256=receipt['binaries'],
                        verified_vendor_source_files=verified_vendor,
                        fresh_full_build_verified=False,compiled_source_build=None)
        manifest['gui_source_update'] = {
            'parent_snapshot':parent.name,'parent_manifest_sha256':expected,
            'artifact_id':candidate['artifact_id'],'artifact_manifest_sha256':bundle.digest(artifact/'manifest.json'),
            'artifact_build_sha256':bundle.digest(artifact/'build.json'),
            'changed_paths':differences,'application_source_changes':changed,
            'recipe_sha256':bundle.digest(Path(__file__)),'core_rebuilt':False,'gui_rebuilt':False,'media_rebuilt':False}
        raw = json.dumps(manifest,sort_keys=True,separators=(',',':'))+'\n'
        checksum = hashlib.sha256(raw.encode()).hexdigest()
        identity = 'farpane-native-source-'+checksum[:24]
        (tree/'source-manifest.json').write_text(raw)
        target = output/identity
        archive = output/(identity+'.tar.gz')
        if target.exists() or archive.exists():
            raise ValueError('Preserving existing snapshot/archive')
        verify_snapshot(tree,checksum,receipt['sources'])
        if bundle.verify(artifact) != candidate or bundle.digest(parent/'source-manifest.json') != expected:
            raise ValueError('Frozen inputs changed during source packaging')
        tree.rename(target)
        print('Compressing verified complete snapshot: '+str(target),flush=True)
        packed=Path(temp)/'source.tar.gz'
        with packed.open('xb') as stream, gzip.GzipFile(filename='',fileobj=stream,mode='wb',mtime=0,compresslevel=6) as compressed:
            with tarfile.open(fileobj=compressed,mode='w|') as tar:
                def normalize(info):
                    info.uid=info.gid=info.mtime=0;info.uname=info.gname=''
                    info.mode=0o755 if info.isdir() or info.mode&0o111 else 0o644;info.pax_headers={}
                    return info
                tar.add(target,arcname=identity,filter=normalize)
        os.link(packed,archive)
        digest=bundle.digest(archive)
        archive.with_suffix('.gz.sha256').write_text(digest+'  '+archive.name+'\n')
        return {'snapshot':str(target),'manifest_sha256':checksum,'archive':str(archive),
                'sha256':digest,'files':len(files),'vendor_packages':manifest['vendor_packages'],
                'changed_paths':differences,'fresh_full_build_verified':False,'complete_license_source_audit':False}


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact',type=Path)
    parser.add_argument('parent',type=Path)
    parser.add_argument('--parent-manifest-sha256',required=True)
    args=parser.parse_args()
    print(json.dumps(package(args.artifact,args.parent,args.parent_manifest_sha256),indent=2))
