#!/usr/bin/env python3
"""Test worker RGBA conversion and bounded GDK output on a private display."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import tempfile
import time

assert Path('/.dockerenv').is_file(), 'This test requires the isolated native-builder container'
assert not os.environ.get('DISPLAY') and not os.environ.get('WAYLAND_DISPLAY')
assert not Path('/tmp/.X11-unix/X93').exists(), 'Do not reuse another display'
root=Path('/workspace/Build/Linux/native-rgba-smoke')/time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())
root.mkdir(parents=True)
print(root,flush=True)
from native_clipboard_writer_smoke import synthetic_png
synthetic_png(root/'max-bytes.png',128*1024*1024)
core_env=dict(os.environ,FARPANE_PRIVATE_RGBA_FIXTURE=str(root),
              CARGO_TARGET_DIR='/workspace/Build/Linux/target',
              VCPKG_ROOT='/workspace/Build/Linux/vcpkg',CXXFLAGS='-include cstdint')
with (root/'core-tests.log').open('w') as log:
    subprocess.run(['cargo','test','--release','--offline','--locked','--no-default-features',
                    '--features','farpane-native,linux-gpu-media','--lib',
                    'farpane_native::viewer_clipboard::tests::',
                    '--','--include-ignored','--test-threads=1','--nocapture'],
                   cwd='/workspace/Build/Linux/src/rustdesk',env=core_env,
                   stdout=log,stderr=subprocess.STDOUT,check=True,timeout=600)
with tempfile.TemporaryDirectory(prefix='farpane-clipboard-') as temporary:
    env=dict(os.environ,DISPLAY=':93',GDK_BACKEND='x11',GTK_A11Y='none',GSK_RENDERER='cairo',
             XDG_RUNTIME_DIR=temporary,XDG_CACHE_HOME=temporary,FARPANE_PRIVATE_CLIPBOARD_TEST='1',
             FARPANE_PRIVATE_RGBA_FIXTURE=str(root))
    server=subprocess.Popen(['Xvfb',':93','-screen','0','320x200x24','-nolisten','tcp'],env=env)
    try:
        deadline=time.monotonic()+3
        while not Path('/tmp/.X11-unix/X93').exists():
            assert server.poll() is None and time.monotonic()<deadline
            time.sleep(.03)
        with (root/'gui-tests.log').open('w') as log:
            subprocess.run(['cargo','test','--offline','--locked',
                            'viewer_clipboard::tests::rgba_is_preconverted_and_png_provider_is_bounded',
                            '--','--exact','--ignored','--nocapture'],cwd='/workspace/Build/Linux/gui',env=env,
                           stdout=log,stderr=subprocess.STDOUT,check=True,timeout=90)
    finally:
        if server.poll() is None:
            server.terminate();server.wait(timeout=3)
result={'result':'pass','checks':['worker_rgba_lossless_png_and_mid_encode_cancellation',
        'maximum_7680x4320_rgba_conversion','sealed_mapping_to_actual_gdk_png_read',
        'actual_clipboard_read_texture_consumer_every_pixel_matches','four_stalled_gio_readers_and_fifth_refused',
        'output_timeout_and_recovery','raw_rgba_provider_refused',
        'third_retained_128_mib_png_refused','storage_recovers_after_release','svg_preference'],
        'fixtures':{name:json.loads((root/(name+'.json')).read_text()) for name in ['small','maximum']},
        'png_files':{name:{'bytes':(root/name).stat().st_size,
             'sha256':hashlib.sha256((root/name).read_bytes()).hexdigest()}
             for name in ['small.png','maximum.png','max-bytes.png']},
        'network':'none','display':'private-xvfb','gpu':'none',
        'scope':'worker function plus actual sealed channel and GDK; not a remote RGBA network or desktop acceptance'}
(root/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result),flush=True)
