#!/usr/bin/env python3
"""Create a self-contained Flutter bundle without installing or starting a service."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'Build/Linux'
bundle = BUILD / 'src/rustdesk/flutter/build/linux/x64/release/bundle'
lock = json.loads((ROOT / 'Linux/dependencies.lock.json').read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if not (bundle / 'farpane').is_file():
        raise SystemExit('Build the FarPane Flutter runner first')
    core = bundle / 'lib/librustdesk.so'
    build_info = json.loads((BUILD / 'core-build.json').read_text())
    if digest(core) != build_info['core_sha256']:
        raise SystemExit('Core does not match its recorded build features')
    gpu = 'linux-gpu-media' in build_info['features']
    if digest(core) != digest(BUILD / 'target/release/liblibrustdesk.so'):
        raise SystemExit('Flutter bundle contains a stale core')
    for path in [bundle / 'farpane', *bundle.glob('lib/*.so')]:
        needed = subprocess.check_output(['readelf', '-d', str(path)], text=True)
        for name in ('libavcodec', 'libavformat', 'libavfilter', 'libavutil', 'libswscale', 'libswresample'):
            if 'Shared library: [' + name in needed:
                raise SystemExit('Unexpected dynamic FFmpeg dependency: ' + str(path))
    artifact_id = (('farpane-p1-' if gpu else 'farpane-b0-') + digest(core)[:12] + '-' +
                   digest(bundle / 'farpane')[:8] + '-' + digest(bundle / 'lib/libapp.so')[:8])
    output = BUILD / 'artifacts' / artifact_id
    if output.exists():
        raise SystemExit('Refusing to replace existing artifact: ' + str(output))
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
        staged = Path(temporary) / artifact_id
        shutil.copytree(bundle, staged)
        drmtap = BUILD / 'drmtap-build' / ('libdrmtap.so.' + lock['libdrmtap']['version'])
        shutil.copyfile(drmtap, staged / 'lib' / drmtap.name)
        (staged / 'lib/libdrmtap.so.0').symlink_to(drmtap.name)
        licenses = staged / 'licenses'
        licenses.mkdir()
        for source, name in [
            (BUILD / 'src/rustdesk/LICENCE', 'rustdesk.txt'),
            (BUILD / 'src/ffmpeg-9.0.2/COPYING.LGPLv2.1', 'ffmpeg.txt'),
            (BUILD / 'src/libdrmtap/LICENSE', 'libdrmtap.txt'),
        ]:
            if not source.exists() and source.name == 'LICENCE':
                source = source.with_name('LICENSE')
            shutil.copyfile(source, licenses / name)
        shutil.copyfile(ROOT / 'Linux/dependencies.lock.json', staged / 'dependencies.lock.json')
        shutil.copytree(ROOT / 'Linux/patches', staged / 'source/patches')
        shutil.copytree(ROOT / 'Linux/src', staged / 'source/overlays')
        (staged / 'README.txt').write_text(
            ('FarPane Linux P1 development app. GPU media is experimental and OFF by default.\n' if gpu else
             'FarPane Linux B0 development app. GPU media is not compiled in.\n') +
            'Flutter GUI with static FFmpeg 9.0.2. Live connection, quality and latency acceptance is pending.\n'
            'Independent FarPane config, IDs, IPC and D-Bus; no RustDesk settings are imported.\n'
            'No service is installed or started by this artifact.\n'
        )
        files = []
        for path in sorted(staged.rglob('*')):
            if path.is_symlink():
                files.append({'path': str(path.relative_to(staged)), 'symlink': str(path.readlink())})
            elif path.is_file():
                files.append({'path': str(path.relative_to(staged)), 'sha256': digest(path)})
        manifest = {
            'artifact_id': artifact_id, 'stage': ('P1 GPU integration' if gpu else 'B0 Flutter app') + '; live acceptance pending',
            'gpu_integrated': gpu, 'gpu_default_enabled': False, 'features': build_info['features'],
            'core_sha256': digest(core), 'files': files,
        }
        (staged / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        staged.rename(output)
    print(output)


if __name__ == '__main__':
    main()
