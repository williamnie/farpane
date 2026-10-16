#!/usr/bin/env python3
"""Materialize pinned upstream sources under ignored Build/Linux, never a worktree.

--reference is a read-only experiment/cache directory, not a source of local edits.
Only Git objects at the pinned revisions and noncredential compiler caches are used.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[2]
LOCK = json.loads((ROOT / 'Linux/dependencies.lock.json').read_text())
BUILD = ROOT / 'Build/Linux'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def checked_file(path, digest):
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise RuntimeError(f'Checksum mismatch: {path.name}')


def apply_patch(target_dir, patch):
    command = ['git', '-C', str(target_dir), 'apply']
    # These archive exports have no .git. Discovering FarPane's outer repo
    # makes git silently skip standard diff --git patches with exit status 0.
    patch_env = {**os.environ, 'GIT_CEILING_DIRECTORIES': str(target_dir.parent)}
    already = subprocess.run([*command, '--reverse', '--check', str(patch)],
                             env=patch_env, capture_output=True).returncode == 0
    if not already:
        run(*command, '--check', str(patch), env=patch_env)
        run(*command, str(patch), env=patch_env)


def export_git(name, source, destination):
    pin = LOCK[name]['commit']
    marker = destination / '.farpane-source-pin'
    if destination.exists() and any(destination.iterdir()):
        if not marker.is_file() or marker.read_text().strip() != pin:
            raise RuntimeError(f'Refusing to overwrite an unknown source tree: {destination}')
        return
    if not source.exists():
        # A missing reference is never an invitation to write into that cache.
        source = BUILD / 'git' / name
        source.parent.mkdir(parents=True, exist_ok=True)
        if not source.exists():
            run('git', 'clone', '--no-checkout', LOCK[name]['url'], str(source))
    # The explicitly supplied read-only cache can be root owned; no global Git config changes.
    git = ['git', '-c', f'safe.directory={source}', '-C', str(source)]
    run(*git, 'cat-file', '-e', pin + '^{commit}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as staging, tempfile.TemporaryFile() as archive:
        run(*git, 'archive', '--format=tar', pin, stdout=archive)
        archive.seek(0)
        with tarfile.open(fileobj=archive) as tar:
            tar.extractall(staging, filter='data')
        (Path(staging) / marker.name).write_text(pin + '\n')
        # Publish only a complete export; interruption cannot create a tree
        # without a marker that prevents a later preparation attempt.
        if destination.exists():
            destination.rmdir()  # only the empty directory passed above
        Path(staging).rename(destination)


def install_overlay(canonical, destination, sha256):
    checked_file(canonical, sha256)
    if destination.exists():
        if destination.read_bytes() != canonical.read_bytes():
            raise RuntimeError(f'Refusing to overwrite a modified overlay: {destination}')
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(canonical, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    args = parser.parse_args()
    reference = args.reference.resolve()
    BUILD.mkdir(parents=True, exist_ok=True)
    downloads = BUILD / 'downloads'
    downloads.mkdir(exist_ok=True)
    meson = LOCK['meson']
    wheel = downloads / meson['filename']
    if not wheel.exists():
        with urlopen(meson['url'], timeout=60) as response:
            wheel.write_bytes(response.read())
    checked_file(wheel, meson['sha256'])
    meson_dir = BUILD / 'tools' / ('meson-' + meson['version'])
    if not meson_dir.exists():
        meson_dir.parent.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=meson_dir.parent) as staging:
            with zipfile.ZipFile(wheel) as archive:
                archive.extractall(staging)
            Path(staging).rename(meson_dir)
    ffmpeg = LOCK['ffmpeg']
    package = downloads / f"ffmpeg-{ffmpeg['version']}.tar.xz"
    if not package.exists():
        with urlopen(ffmpeg['url'], timeout=60) as response:
            package.write_bytes(response.read())
    checked_file(package, ffmpeg['sha256'])
    source = BUILD / 'src'
    source.mkdir(exist_ok=True)
    if not (source / f"ffmpeg-{ffmpeg['version']}").exists():
        with tarfile.open(package) as tar:
            tar.extractall(source, filter='data')
    export_git('rustdesk', reference / 'rustdesk', source / 'rustdesk')
    export_git('hbb_common', reference / 'rustdesk/libs/hbb_common', source / 'rustdesk/libs/hbb_common')
    candidates = list((reference / 'cache/cargo/git/checkouts').glob('hwcodec-*/*/.git'))
    hwcodec = next((p.parent for p in candidates if p.parent.name == LOCK['hwcodec']['commit'][:7]), BUILD / 'git/hwcodec')
    export_git('hwcodec', hwcodec, source / 'hwcodec')
    export_git('hwcodec_externals', hwcodec / 'externals', source / 'hwcodec/externals')
    export_git('libdrmtap', BUILD / 'git/libdrmtap', source / 'libdrmtap')
    for entry in LOCK['patches']:
        patch = ROOT / entry['path']
        checked_file(patch, entry['sha256'])
        target = entry.get('target', 'rustdesk')
        if target not in ('rustdesk', 'hwcodec', 'ffmpeg'):
            raise RuntimeError(f'Unknown patch target: {target}')
        target_dir = source / (f"ffmpeg-{ffmpeg['version']}" if target == 'ffmpeg' else target)
        apply_patch(target_dir, patch)
    for entry in LOCK.get('overlays', []):
        install_overlay(ROOT / entry['path'], source / 'rustdesk' / entry['target'], entry['sha256'])
    for entry in LOCK['lockfiles']:
        canonical = ROOT / entry['path']
        checked_file(canonical, entry['sha256'])
        relative = 'Cargo.lock' if canonical.name == 'Cargo.lock' else 'flutter/pubspec.lock'
        destination = source / 'rustdesk' / relative
        if destination.read_bytes() != canonical.read_bytes():
            original = subprocess.check_output([
                'git', '-c', f'safe.directory={reference / "rustdesk"}',
                '-C', str(reference / 'rustdesk'), 'show',
                f'{LOCK["rustdesk"]["commit"]}:{relative}',
            ])
            if destination.read_bytes() != original:
                raise RuntimeError(f'Refusing to overwrite a modified lockfile: {destination}')
            shutil.copyfile(canonical, destination)
    # Root-owned public compiler caches stay mounted read-only. Never copy Cargo
    # credentials/config; the short-lived builder copies only git and registry data.
    run('bash', str(ROOT / 'Scripts/linux/prepare-cache.sh'), str(reference))
    prefix = BUILD / 'vcpkg/installed/x64-linux'
    # Both Rust profiles deliberately link the same new PIC archives in lib/.
    # The reference's debug/lib still contains 7.x; preserve it outside every
    # link/pkg-config search root so another build helper cannot select it.
    debug_lib = prefix / 'debug/lib'
    retired = BUILD / 'retired/cached-ffmpeg-debug'
    for stem in ['libavutil', 'libavcodec', 'libavformat', 'libavfilter', 'libavdevice', 'libswscale', 'libswresample', 'libpostproc']:
        candidates = list(debug_lib.glob(stem + '*'))
        candidates += list((debug_lib / 'pkgconfig').glob(stem + '.pc'))
        for path in candidates:
            destination = retired / path.relative_to(debug_lib)
            if destination.exists():
                raise RuntimeError(f'Refusing to overwrite retired cache: {destination}')
            destination.parent.mkdir(parents=True, exist_ok=True)
            path.rename(destination)
            print(f'Retired old FFmpeg cache: {path.relative_to(BUILD)}')
    if not (BUILD / 'vcpkg/.farpane-nonffmpeg-cache').exists():
        # Remove every old FFmpeg header/archive before installing the one pinned ABI.
        for stem in ['libavutil', 'libavcodec', 'libavformat', 'libavfilter', 'libavdevice', 'libswscale', 'libswresample', 'libpostproc']:
            shutil.rmtree(prefix / 'include' / stem, ignore_errors=True)
            for path in (prefix / 'lib').glob(stem + '*'):
                if path.is_file() or path.is_symlink():
                    path.unlink()
            (prefix / 'lib/pkgconfig' / (stem + '.pc')).unlink(missing_ok=True)
        (BUILD / 'vcpkg/.farpane-nonffmpeg-cache').write_text(LOCK['vcpkg']['commit'] + '\n')
    amf = LOCK['amf_headers']
    archive = downloads / f"AMF-v{amf['version']}.tar.gz"
    if not archive.exists():
        with urlopen(amf['url'], timeout=60) as response:
            archive.write_bytes(response.read())
    checked_file(archive, amf['sha256'])
    if not (source / f"AMF-{amf['version']}/amf/public/include/core/Version.h").exists():
        with tarfile.open(archive) as tar:
            members = [m for m in tar if m.name.startswith(f"AMF-{amf['version']}/amf/public/include/")]
            tar.extractall(source, members=members, filter='data')
    shutil.copytree(source / f"AMF-{amf['version']}/amf/public/include", prefix / 'include/AMF', dirs_exist_ok=True)
    print('Pinned Linux sources and independent caches prepared under Build/Linux')


if __name__ == '__main__':
    main()
