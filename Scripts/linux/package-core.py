#!/usr/bin/env python3
"""Stage the B0 core for review; this never installs or starts RustDesk."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[2]
BUILD=ROOT/'Build/Linux'
core=BUILD/'target/release/liblibrustdesk.so'
sha=hashlib.sha256(core.read_bytes()).hexdigest()
build_info=BUILD/'core-build.json'
if build_info.exists():
    info=json.loads(build_info.read_text())
    if info['core_sha256'] != sha or info['features'] != ['flutter','hwcodec','drm']:
        raise SystemExit('This is not a B0 core build; use package-app.py for FarPane/GPU builds')
out=BUILD/'artifacts'/('b0-'+sha[:12])
if out.exists():
    raise SystemExit('Artifact already exists: '+str(out))
needed=subprocess.check_output(['readelf','-d',str(core)],text=True)
if any('Shared library: ['+name in needed for name in ('libavcodec','libavformat','libavfilter','libavutil','libswscale','libswresample')):
    raise SystemExit('Unexpected system FFmpeg link')
(out/'lib').mkdir(parents=True)
shutil.copyfile(core,out/'lib/librustdesk.so')
(out/'licenses').mkdir()
for source,dest in [(BUILD/'src/rustdesk/LICENCE','rustdesk.txt'),(BUILD/'src/ffmpeg-9.0.2/COPYING.LGPLv2.1','ffmpeg.txt')]:
    if not source.exists() and source.name=='LICENCE': source=source.with_name('LICENSE')
    shutil.copyfile(source,out/'licenses'/dest)
shutil.copyfile(ROOT/'Linux/dependencies.lock.json',out/'dependencies.lock.json')
shutil.copyfile(BUILD/'ffmpeg-build/config.h',out/'ffmpeg-config.h')
shutil.copytree(ROOT/'Linux/patches',out/'patches')
manifest={'stage':'B0 core only; not an installable app or release', 'gpu_integration':False,
          'profile':'release','features':['flutter','hwcodec','drm'], 'core_sha256':sha,
          'ffmpeg':'9.0.2 static', 'runtime':'x86_64 Ubuntu 26.04.1 builder ABI; other distributions unverified',
          'files':[]}
(out/'README.txt').write_text('B0 review artifact only. GPU integration is not implemented.\nDo not overwrite an installed RustDesk core without a separate maintenance window.\nStatic FFmpeg libraries are included in the core; system GPU drivers remain external.\nSee Linux/README.md and Linux/docs/p0-status.md for verified scope and open gates.\n')
for file in sorted(out.rglob('*')):
    if file.is_file(): manifest['files'].append({'path':str(file.relative_to(out)),'sha256':hashlib.sha256(file.read_bytes()).hexdigest()})
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(out)
