#!/usr/bin/env python3
"""Bounded native clipboard against an owned compositor; never a host desktop."""
from pathlib import Path
import hashlib,json,os,signal,subprocess,sys,time
from native_clipboard_writer_smoke import synthetic_png,digest,rgba_pixels

assert Path('/.dockerenv').is_file()
assert not os.environ.get('DISPLAY') and not os.environ.get('WAYLAND_DISPLAY')
mode=sys.argv[1];assert mode in ('supported','unavailable')
root=Path('/workspace/Build/Linux/wayland-clipboard-smoke')/time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())
root.mkdir(parents=True);print(root,flush=True)
manifest=Path('/farpane-native-clipboard-test-packages.txt' if mode=='supported' else '/farpane-native-display-test-packages.txt')
assert manifest.is_file();(root/'test-image-packages.txt').write_bytes(manifest.read_bytes())
runtime=root/'runtime';runtime.mkdir(mode=0o700)
env=dict(os.environ,XDG_RUNTIME_DIR=str(runtime),XDG_CONFIG_HOME=str(runtime/'config'),
         XDG_CACHE_HOME=str(runtime/'cache'),XDG_DATA_HOME=str(runtime/'data'),XDG_SESSION_TYPE='wayland',
         FARPANE_PRIVATE_WAYLAND_CLIPBOARD_TEST=str(root))
if mode=='supported':
    synthetic_png(root/'max.png',128*1024*1024)
    config=root/'sway.conf';config.write_text('xwayland disable\noutput HEADLESS-1 resolution 320x200\nseat seat0 fallback true\n')
    env.update(WLR_BACKENDS='headless',WLR_RENDERER='pixman',WLR_LIBINPUT_NO_DEVICES='1')
    args=['dbus-run-session','--','sway','--config',str(config)]
else:
    args=['weston','--backend=headless','--renderer=pixman','--socket=wayland-farpane-test','--width=320','--height=200','--idle-time=0']
with (root/'compositor.log').open('w') as log:
    compositor=subprocess.Popen(args,env=env,stdout=log,stderr=log,start_new_session=True)
try:
    deadline=time.monotonic()+8
    while True:
        sockets=[p for p in runtime.glob('wayland-*') if p.is_socket()]
        if sockets:break
        assert compositor.poll() is None and time.monotonic()<deadline,'Private compositor did not start'
        time.sleep(.03)
    assert len(sockets)==1;env['WAYLAND_DISPLAY']=sockets[0].name
    reports=[]
    for protocol in (('ext','wlr') if mode=='supported' else ('unavailable',)):
        env['FARPANE_PRIVATE_WAYLAND_PROTOCOL']=protocol
        with (root/f'{protocol}-test.log').open('w') as log:
            subprocess.run(['cargo','test','--offline','--locked','--no-default-features','--features','farpane-native,linux-gpu-media',
                '--lib','farpane_native::clipboard_wayland::tests::private_wayland_clipboard_lifecycle','--','--exact','--ignored','--nocapture'],
                cwd='/workspace/Build/Linux/src/rustdesk',env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=240)
        report=json.loads((root/f'{protocol}-result.json').read_text());assert report['result']=='pass'
        if mode=='supported':
            assert digest(root/'max.png')==digest(root/f'{protocol}-max-result.png')
            assert digest(root/'max.png')==digest(root/f'{protocol}-old-result.png')
            assert rgba_pixels(root/f'{protocol}-rgba-result.png')==b'\x01\x02\x03\0\x09\x08\x07\xff'
            report['png_sha256']=digest(root/'max.png')
        reports.append(report)
    (root/'result.json').write_text(json.dumps({'result':'pass','mode':mode,'rounds':reports,'host_display_or_gpu':False},indent=2))
    print(json.dumps(reports),flush=True)
finally:
    if compositor.poll() is None:
        os.killpg(compositor.pid,signal.SIGTERM)
        try:compositor.wait(timeout=5)
        except subprocess.TimeoutExpired:os.killpg(compositor.pid,signal.SIGKILL);compositor.wait()
