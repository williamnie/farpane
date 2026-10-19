#!/usr/bin/env python3
"""Actual loopback login/video/GTK/exit, confined to the native test container."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
import ctypes
import re
import signal
from native_host_smoke import cli, RELEASE, RUNTIME, stage_release


def gpu_mode():
    return os.environ.get('FARPANE_NATIVE_TEST_MODE') in ('gpu','gpu-x11')


def memory_breakdown(raw):
    mappings={};name='[anonymous]'
    for line in raw.splitlines():
        if re.match(r'^[0-9a-f]+-[0-9a-f]+ ',line):
            fields=line.split(maxsplit=5);name=fields[5] if len(fields)==6 else '[anonymous]'
        elif line.startswith(('Pss:','Private_Dirty:','Anonymous:')):
            key,value,*_=line.split();row=mappings.setdefault(name,{'path':name})
            row[key[:-1]]=row.get(key[:-1],0)+int(value)
    rows=sorted(mappings.values(),key=lambda row:row.get('Pss',0),reverse=True)
    return {'pss_kib':sum(row.get('Pss',0) for row in rows),'mappings':rows}


def exercise_input(directory):
    # These X servers exist only inside this container; never use $DISPLAY.
    x11 = ctypes.CDLL('libX11.so.6'); xtst = ctypes.CDLL('libXtst.so.6')
    x11.XOpenDisplay.argtypes=[ctypes.c_char_p];x11.XOpenDisplay.restype=ctypes.c_void_p
    x11.XKeysymToKeycode.argtypes=[ctypes.c_void_p,ctypes.c_ulong];x11.XKeysymToKeycode.restype=ctypes.c_uint
    x11.XFlush.argtypes=[ctypes.c_void_p];x11.XCloseDisplay.argtypes=[ctypes.c_void_p]
    x11.XSetInputFocus.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_int,ctypes.c_ulong]
    x11.XQueryKeymap.argtypes=[ctypes.c_void_p,ctypes.c_void_p]
    x11.XDefaultRootWindow.argtypes=[ctypes.c_void_p];x11.XDefaultRootWindow.restype=ctypes.c_ulong
    x11.XCreateSimpleWindow.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_int,ctypes.c_int,ctypes.c_uint,ctypes.c_uint,ctypes.c_uint,ctypes.c_ulong,ctypes.c_ulong]
    x11.XCreateSimpleWindow.restype=ctypes.c_ulong
    x11.XMapWindow.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
    x11.XDestroyWindow.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
    x11.XTranslateCoordinates.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_ulong,ctypes.c_int,ctypes.c_int,ctypes.POINTER(ctypes.c_int),ctypes.POINTER(ctypes.c_int),ctypes.POINTER(ctypes.c_ulong)]
    x11.XTranslateCoordinates.restype=ctypes.c_int
    xtst.XTestFakeMotionEvent.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_ulong]
    xtst.XTestFakeButtonEvent.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_int,ctypes.c_ulong]
    xtst.XTestFakeKeyEvent.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_int,ctypes.c_ulong]
    display=x11.XOpenDisplay(b':92');assert display
    tree=subprocess.check_output(['xwininfo','-display',':92','-root','-tree'],text=True)
    window=re.search(r'(0x[0-9a-f]+) "FarPane"',tree);assert window,tree
    x11.XSetInputFocus(display,int(window[1],16),2,0);x11.XFlush(display)
    def key(symbol, down):
        code=x11.XKeysymToKeycode(display,symbol);assert code
        xtst.XTestFakeKeyEvent(display,code,int(down),0);x11.XFlush(display);time.sleep(.06)
    def click(x,y):
        xtst.XTestFakeMotionEvent(display,-1,x,y,0);x11.XFlush(display);time.sleep(.06)
        xtst.XTestFakeButtonEvent(display,1,1,0);xtst.XTestFakeButtonEvent(display,1,0,0);x11.XFlush(display);time.sleep(.15)
    try:
        click(510,380)
        key(ord('a'),True);key(ord('a'),False)
        # GTK's real simple input method: Ctrl+Shift+u 4e2d Return -> 中.
        key(0xffe3,True);key(0xffe1,True);key(ord('u'),True);key(ord('u'),False)
        key(0xffe1,False);key(0xffe3,False)
        for letter in '4e2d':key(ord(letter),True);key(ord(letter),False)
        key(0xff0d,True);key(0xff0d,False)
        # A held Ctrl must be released when the local HUD takes focus. The HUD
        # click itself must never become an extra remote mouse click.
        host=x11.XOpenDisplay(b':91');assert host
        try:
            control=x11.XKeysymToKeycode(host,0xffe3)
            def held(code):
                keys=ctypes.create_string_buffer(32);x11.XQueryKeymap(host,keys)
                return bool(keys.raw[code//8] & (1<<(code%8)))
            key(0xffe3,True)
            deadline=time.monotonic()+1
            while not held(control) and time.monotonic()<deadline:time.sleep(.02)
            assert held(control), 'Remote Ctrl did not become held before deactivation'
            # Use a separate top-level, as a real application switch does.
            # Focusing the root sends NotifyAncestor, not normal deactivation.
            other=x11.XCreateSimpleWindow(display,x11.XDefaultRootWindow(display),0,0,10,10,0,0,0)
            assert other
            x11.XMapWindow(display,other)
            x11.XSetInputFocus(display,other,2,0);x11.XFlush(display);time.sleep(.3)
            assert not held(control), 'Deactivating GUI left remote Ctrl pressed'
            x11.XSetInputFocus(display,int(window[1],16),2,0);x11.XFlush(display)
            x11.XDestroyWindow(display,other)
            # Follow the actual widget allocation; new toolbar buttons must not
            # silently turn this local-HUD test into opening another window.
            target=json.loads((directory/'input-targets.json').read_text())['hud']
            x=ctypes.c_int();y=ctypes.c_int();child=ctypes.c_ulong()
            assert x11.XTranslateCoordinates(display,int(window[1],16),x11.XDefaultRootWindow(display),round(target[0]),round(target[1]),ctypes.byref(x),ctypes.byref(y),ctypes.byref(child))
            key(0xffe3,False);click(x.value,y.value)
            deadline=time.monotonic()+1
            while time.monotonic()<deadline:
                if json.loads((directory/'viewer-progress.json').read_text()).get('hud_enabled'):break
                time.sleep(.02)
            else:raise AssertionError('Actual HUD button did not enable the HUD')
            for symbol in [0xffe3,0xffe1,0xffe9]:
                code=x11.XKeysymToKeycode(host,symbol)
                assert not held(code), f'Remote modifier {symbol:x} remained pressed'
            # Hold a new key through the normal Viewer close. The worker must
            # release its own remote ledger even when the GUI queue is stopped.
            click(510,380);key(0xffe3,True)
            deadline=time.monotonic()+1
            while not held(control) and time.monotonic()<deadline:time.sleep(.02)
            assert held(control), 'Remote Ctrl was not held before disconnect'
            deadline=time.monotonic()+12
            while not (directory/'viewer.json').exists() and time.monotonic()<deadline:time.sleep(.05)
            assert (directory/'viewer.json').exists(), 'Viewer did not complete disconnect'
            assert not held(control), 'Disconnect left remote Ctrl pressed'
            key(0xffe3,False)
        finally:x11.XCloseDisplay(host)
        (directory/'input-driver.json').write_text(json.dumps({'target_display':':92','keyboard':'a','ime':'中','window_deactivation_release':True,'remote_modifiers_released':True,'disconnect_release':True}))
    finally:x11.XCloseDisplay(display)


def exercise_clipboard(directory, helper):
    from native_clipboard_smoke import exercise
    exercise(directory, helper)


def sample_processes(directory, gui, agent):
    children = set()
    for task in Path(f'/proc/{gui.pid}/task').iterdir():
        try: children.update(int(pid) for pid in (task/'children').read_text().split())
        except FileNotFoundError: pass
    viewers = [pid for pid in children if Path(f'/proc/{pid}/exe').resolve()==RELEASE/'libexec/farpane-core'
               and b'--viewer\0' in Path(f'/proc/{pid}/cmdline').read_bytes()]
    assert len(viewers)==1, f'Expected one private Viewer process: {viewers}'
    gpu_test = gpu_mode()
    report = {'time_unix': time.time(), 'backend':'pending-verification' if gpu_test else 'software', 'root_service':False, 'gpu':gpu_test, 'processes':{}}
    for role, pid in [('gui',gui.pid), ('viewer',viewers[0]), ('host',agent.pid)]:
        raw = Path(f'/proc/{pid}/smaps_rollup').read_text()
        (directory/f'{role}-smaps-rollup.txt').write_text(raw)
        values = {line.split(':')[0]:int(line.split()[1]) for line in raw.splitlines()[1:] if ':' in line}
        report['processes'][role] = {'pid':pid,'pss_kib':values['Pss'],'rss_kib':values['Rss']}
        (directory/f'{role}-maps.txt').write_text(Path(f'/proc/{pid}/maps').read_text())
        profile=memory_breakdown(Path(f'/proc/{pid}/smaps').read_text())
        (directory/f'{role}-pss-by-mapping.json').write_text(json.dumps(profile,indent=2))
    (directory/'process-sample.json').write_text(json.dumps(report, indent=2))


def user_test(output):
    if os.environ.get('FARPANE_NATIVE_TEST_MODE') in ('recovery','auto-reconnect'):
        # The private bus supplies fixture system names; no host bus is mounted.
        os.environ['DBUS_SYSTEM_BUS_ADDRESS']=os.environ['DBUS_SESSION_BUS_ADDRESS']
    gpu_test = gpu_mode()
    xwayland = os.environ.get('FARPANE_NATIVE_TEST_MODE')=='gpu-x11'
    core = RELEASE/'libexec/farpane-core'
    state = cli({'type': 'snapshot'})
    state = cli({'type': 'set_authentication', 'data': {
        'mode': 'permanent', 'password': 'native-viewer-smoke', 'revision': state['revision']}})
    state = cli({'type': 'set_host', 'data': {'enabled': True, 'revision': state['revision']}})
    if os.environ.get('FARPANE_NATIVE_TEST_MODE') == 'clipboard':
        state = cli({'type': 'set_host_clipboard', 'data': {
            'policy': {kind: {'send': True, 'receive': True} for kind in ('text', 'rich_text', 'image')},
            'revision': state['revision']}})
    # Only synthetic test files, before the agent owns configuration. Direct TCP
    # lives entirely within the container's loopback-only network namespace.
    settings = next(Path(os.environ['XDG_CONFIG_HOME']).rglob('FarPane2.toml'))
    text = settings.read_text()
    assert '[options]\n' in text and 'direct-server' not in text
    text=text.replace('[options]\n', '[options]\ndirect-server = "Y"\n', 1)
    if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='clipboard':
        text,count=re.subn(r'''(?m)^enable-clipboard\s*=\s*["']N["']$''','enable-clipboard = "Y"',text)
        assert count==1, 'Missing synthetic clipboard policy'
    settings.write_text(text)
    if os.environ.get('FARPANE_NATIVE_TEST_MODE') in ('two-factor','two-factor-files'):
        from native_two_factor_smoke import seed
        seed(settings, output)
    processes = []
    logs = []
    private_secrets=None
    secrets_test=os.environ.get('FARPANE_NATIVE_TEST_MODE')=='secrets'
    secrets_unavailable=os.environ.get('FARPANE_NATIVE_TEST_MODE')=='secrets-unavailable'
    secrets_locked=os.environ.get('FARPANE_NATIVE_TEST_MODE')=='secrets-locked'
    def start(name, args, env=None, stdin_bytes=None):
        log = (output/f'{name}.log').open('w'); logs.append(log)
        process = subprocess.Popen(args, env=env, stdout=log, stderr=subprocess.STDOUT,
                                   stdin=subprocess.PIPE if stdin_bytes is not None else None)
        if stdin_bytes is not None:process.stdin.write(stdin_bytes);process.stdin.close()
        processes.append(process)
        return process
    try:
        if secrets_test or os.environ.get('FARPANE_NATIVE_TEST_MODE') in ('files-secrets','secrets-boundary','secrets-locked','two-factor','two-factor-files'):
            from native_secrets_smoke import PrivateSecrets
            private_secrets=PrivateSecrets(output,start)
            private_secrets.seed_isolation(state['server'])
        if os.environ.get('FARPANE_NATIVE_TEST_MODE','').startswith('files') or os.environ.get('FARPANE_NATIVE_TEST_MODE')=='two-factor-files':
            from native_files_smoke import setup_files
            setup_files(output)
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='audio':
            from native_audio_smoke import setup_audio
            private_audio=setup_audio(output,start)
        multidisplay = os.environ.get('FARPANE_NATIVE_TEST_MODE') == 'multidisplay'
        host_size = '960x480x24' if multidisplay else '256x128x24' if gpu_test else '640x480x24'
        start('host-xvfb', ['Xvfb', ':91', '-screen', '0', host_size, '-nolisten', 'tcp']
              + (['-noreset'] if multidisplay else []))
        if gpu_test:
            start('weston', ['weston','--backend=headless','--renderer=gl','--width=1020','--height=720',
                            '--refresh-rate=12000','--socket=farpane-test-wayland','--no-config','--idle-time=0']+(['--xwayland'] if xwayland else []))
        else:
            start('gui-xvfb', ['Xvfb', ':92', '-screen', '0', '1020x720x24', '-nolisten', 'tcp'])
        deadline = time.monotonic()+5
        paths = [Path('/tmp/.X11-unix/X91'), RUNTIME/'farpane-test-wayland' if gpu_test else Path('/tmp/.X11-unix/X92')]
        while not all(path.exists() for path in paths):
            assert time.monotonic() < deadline, 'Private X server startup timeout'
            time.sleep(.05)
        if secrets_locked or os.environ.get('FARPANE_NATIVE_TEST_MODE')=='secrets-boundary':
            private_secrets.bridge_checks()
            if not secrets_locked:
                print((output/'secret-bridge-result.json').read_text())
                return
        host_env = dict(os.environ, DISPLAY=':91', RUST_LOG='info', RUST_BACKTRACE='1')
        desktop_bus = None
        if os.environ.get('FARPANE_NATIVE_TEST_MODE') == 'desktop-bus':
            from native_desktop_bus_smoke import PrivateBus
            desktop_bus = PrivateBus(output, start)
            host_env['DBUS_SESSION_BUS_ADDRESS'] = desktop_bus.address
        if multidisplay:
            from native_multidisplay_smoke import configure_monitors
            configure_monitors(output)
            if os.environ.get('FARPANE_MONITOR_ALLOCATOR_CHECK') == '1':
                # Private regression diagnostic: glibc overwrites freed memory.
                # This must never become a production allocator setting.
                host_env.update(GLIBC_TUNABLES='glibc.malloc.tcache_count=0', MALLOC_PERTURB_='165')
        input_test = os.environ.get('FARPANE_NATIVE_TEST_MODE')=='input'
        if input_test:
            start('pattern',['stdbuf','-oL','xev','-display',':91','-geometry','600x360+20+20','-name','FarPaneInputSmoke'],host_env)
        else:
            start('pattern', ['xmessage', '-display', ':91', '-bg', '#205090', '-fg', 'white',
                  '-geometry', '240x100+4+4' if gpu_test else '600x360+20+20', 'FarPane native Viewer\nPrivate synthetic desktop\nActual TCP loopback session'], host_env)
        agent = start('agent', [str(core), '--server'], host_env)
        deadline = time.monotonic()+15
        while True:
            assert agent.poll() is None, 'Agent exited before direct server readiness'
            try:
                with socket.create_connection(('127.0.0.1', 21118), timeout=.2): break
            except OSError:
                assert time.monotonic() < deadline, 'Missing private direct listener'
                time.sleep(.1)
        if os.environ.get('FARPANE_NATIVE_TEST_MODE','').startswith('files'):
            from native_files_smoke import exercise_files
            exercise_files(output,agent)
            if private_secrets:
                private_secrets.verify(True)
                (output/'file-secrets-result.json').write_text(json.dumps({'result':'pass','authenticated-file-password-stored':True,'isolation':True,'no-plaintext-config-fallback':True},indent=2))
            return
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='hud':
            from native_hud_smoke import exercise_hud
            exercise_hud(output,agent,start)
            return
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='auto-reconnect':
            from native_auto_reconnect_smoke import exercise_auto_reconnect
            exercise_auto_reconnect(output,agent,start)
            return
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='recovery':
            from native_recovery_smoke import exercise_recovery
            exercise_recovery(output,agent,start)
            return
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='desktop':
            from native_desktop_smoke import exercise_desktop
            exercise_desktop(output,agent,start)
            return
        if desktop_bus is not None:
            from native_desktop_bus_smoke import exercise
            exercise(output, agent, start, desktop_bus)
            return
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='approval':
            from native_inbound_smoke import exercise_inbound
            exercise_inbound(output,agent,start)
            return
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='audio':
            from native_audio_smoke import exercise_audio_ui
            exercise_audio_ui(output)
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='clipboard':
            from native_clipboard_smoke import exercise_host_ui
            exercise_host_ui(output)
        initial = cli({'type': 'snapshot'})
        assert initial['role']=='agent' and initial['host_enabled']
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='two-factor':
            from native_two_factor_smoke import exercise
            exercise(output,start,agent,initial,private_secrets)
            return
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='two-factor-files':
            from native_two_factor_smoke import exercise_file_auth
            exercise_file_auth(output,agent,initial,private_secrets)
            return
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='lifecycle':
            from native_lifecycle_smoke import exercise
            exercise(output,start,agent,initial)
            return
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='sustained':
            from native_sustained_smoke import exercise
            exercise(output,start,agent,initial)
            return
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='keyboard':
            from native_keyboard_smoke import exercise
            exercise(output,start,agent,initial)
            return
        if multidisplay:
            from native_multidisplay_smoke import exercise
            exercise(output,start,agent,initial)
            return
        if os.environ.get('FARPANE_NATIVE_TEST_HOME_ONLY')=='1':
            from native_home_memory import exercise
            exercise(output,start,agent,initial)
            return
        retry_test=os.environ.get('FARPANE_NATIVE_TEST_MODE')=='retry'
        for index in range(5 if secrets_test else 1 if retry_test else 2):
            if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='clipboard':
                state = cli({'type':'snapshot'})
                clipboard_revision_before=state['revision']
                cli({'type':'set_host_clipboard','data':{'policy':{k:{'send':True,'receive':True} for k in ('text','rich_text','image')},'revision':state['revision']}})
            directory = output/f'viewer-{index}'; directory.mkdir()
            input_start=(output/'pattern.log').stat().st_size
            gui_env = dict(os.environ, DISPLAY=':92', FARPANE_VIEWER_SMOKE_DIR=str(directory),
                           GSK_RENDERER='cairo', GTK_A11Y='none', GTK_IM_MODULE='gtk-im-context-simple')
            if secrets_test:
                gui_env['FARPANE_SECRET_ROUND']=['save','load','cancel','stale','delete'][index]
                if index==3:private_secrets.seed_password('outdated-synthetic-password')
                if index in (2,3):private_secrets.pause()
            if secrets_unavailable:gui_env['FARPANE_SECRET_ROUND']='unavailable'
            if secrets_locked:gui_env['FARPANE_SECRET_ROUND']='locked'
            if gpu_test:
                gui_env.pop('DISPLAY',None)
                gui_env.update(GDK_BACKEND='wayland',WAYLAND_DISPLAY='farpane-test-wayland',GSK_RENDERER='gl')
                if xwayland:
                    # Xwayland is spawned by this private compositor, never a
                    # host X server. Weston advertises its own display number.
                    match=re.search(r'xserver listening on display (:[0-9]+)',(output/'weston.log').read_text())
                    assert match, 'Private Xwayland listener was not announced'
                    gui_env.update(GDK_BACKEND='x11',DISPLAY=match[1])
                    gui_env.pop('WAYLAND_DISPLAY',None)
            if os.environ.get('FARPANE_NATIVE_MEMORY_PROBE')=='arena2':gui_env['MALLOC_ARENA_MAX']='2'
            if os.environ.get('FARPANE_NATIVE_MEMORY_PROBE')=='mmap128k':
                gui_env.update(MALLOC_MMAP_THRESHOLD_='131072',MALLOC_TRIM_THRESHOLD_='131072')
            if os.environ.get('FARPANE_NATIVE_MEMORY_PROBE') in ('identity','mmap128k'):
                gui_env['LD_PRELOAD']=str(output/'gl-identity.so')
            gui = start(f'gui-{index}', [str(RELEASE/'farpane')], gui_env)
            deadline = time.monotonic()+(110 if os.environ.get("FARPANE_NATIVE_TEST_MODE")=="clipboard" else 40)
            sampled = False
            while gui.poll() is None and time.monotonic() < deadline:
                if secrets_test:
                    try:progress=json.loads((directory/'viewer-progress.json').read_text())
                    except (FileNotFoundError,json.JSONDecodeError):progress={}
                    if index==0 and progress.get('password_attempts')==1:
                        assert private_secrets.lookup(initial['server']) is None,'Incorrect password was saved'
                        (directory/'wrong-password-not-stored').touch()
                    if index==2 and (directory/'secret-started').exists():
                        (directory/'cancel-keyring').touch()
                    if index==2 and (directory/'secret-cancelled').exists():private_secrets.resume()
                    if index==3 and (directory/'secret-started').exists():(directory/'submit-manually').touch()
                    if index==3 and (directory/'manual-submitted').exists():private_secrets.resume()
                if not sampled and (directory/'viewer-window.png').exists():
                    sample_processes(directory, gui, agent); sampled = True
                    if private_secrets:private_secrets.sample(directory)
                    if retry_test:
                        # Only the child discovered under this private GUI, not
                        # a name-matched process or any installed runtime.
                        sample=json.loads((directory/'process-sample.json').read_text())
                        worker=sample['processes']['viewer']['pid']
                        # Popen runs on GUI's control thread, so the child's
                        # task-local list need not belong to the main thread.
                        handle=os.pidfd_open(worker)
                        try:
                            status=Path(f'/proc/{worker}/status').read_text()
                            assert int(re.search(r'^PPid:\s+(\d+)',status,re.M)[1])==gui.pid
                            assert Path(f'/proc/{worker}/exe').resolve()==core
                            signal.pidfd_send_signal(handle,signal.SIGKILL)
                        finally: os.close(handle)
                        (directory/'injected-crash.json').write_text(json.dumps({'gui_pid':gui.pid,'worker_pid':worker,'signal':'SIGKILL'}))
                    if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='audio':
                        from native_audio_smoke import exercise_audio
                        exercise_audio(directory,private_audio,fault=index==1)
                    if input_test:exercise_input(directory)
                    if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='cursor':
                        from native_cursor_smoke import exercise_cursor
                        exercise_cursor(directory)
                    if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='clipboard':exercise_clipboard(directory,output/'clipboard-fixture')
                time.sleep(.05)
            if gui.poll() is None:
                gui.kill(); gui.wait()
                raise AssertionError('GUI did not complete actual Viewer session within 40 seconds')
            code = gui.returncode
            assert code == 0, f'GUI failed: {code}'
            report = json.loads((directory/'viewer.json').read_text())
            if retry_test:
                first=json.loads((directory/'cycle-0.json').read_text())
                second=json.loads((directory/'cycle-1.json').read_text())
                assert first['session']!=second['session'] and first['worker_reaped'] and second['worker_reaped']
                assert first['presented'] and second['presented'] and second['cycle']==1
                assert report==second
            if (directory/'audio-failure.json').exists():
                failure=json.loads((directory/'audio-failure.json').read_text())
                assert report['frames']>failure['video_frames_before_refresh'], 'Audio service failure prevented video refresh'
            if secrets_test or secrets_unavailable or secrets_locked:
                assert report['password_attempts']==(2 if secrets_test and index==0 else 1),report['password_attempts']
                if secrets_test:private_secrets.verify(index!=4)
                if secrets_locked:
                    assert '被锁定' in json.loads((directory/'secret-progress.json').read_text())['status']
                    private_secrets.verify_locked()
            else:assert report['password_attempts'] >= 2, 'Wrong-password retry not exercised'
            assert report['presented'] and report['frames'] > 0 and report['worker_reaped']
            if not gpu_test: assert (directory/'remote-frame.png').read_bytes().startswith(b'\x89PNG')
            assert (directory/'viewer-window.png').read_bytes().startswith(b'\x89PNG')
            assert sampled, 'Missing live process sample'
            assert not any(e['event']['type']=='phase' and e['event']['data']['phase']=='failed' for e in report['events']), report
            assert agent.poll() is None, 'Closing Viewer terminated Host'
            after = cli({'type': 'snapshot'})
            # Only successful first presentation records history. Auth/network/
            # media settings and the Host identity remain untouched.
            clipboard_test=os.environ.get('FARPANE_NATIVE_TEST_MODE')=='clipboard'
            if clipboard_test:
                clipboard_report=json.loads((directory/'clipboard-result.json').read_text())
                assert after['revision']==clipboard_revision_before+2+clipboard_report['host_policy_transactions']
            else:
                assert after['revision']==initial['revision']+(2 if retry_test else index+1)
            assert len(after['devices'])==1 and after['devices'][0]['peer']=='127.0.0.1:21118'
            assert after['devices'][0]['last_connected']>0
            assert after['devices'][0]['remote_name']==socket.gethostname(),after['devices']
            stable=('local_id','host_enabled','authentication','permanent_password_set','temporary_password','server','sharing','gpu_enabled')
            if clipboard_test:
                stable=tuple(k for k in stable if k!='sharing')
                expected_sharing=json.loads(json.dumps(initial['sharing']))
                expected_sharing['clipboard']={k:{'send':False,'receive':False} for k in ('text','rich_text','image')}
                expected_sharing['permissions']['clipboard']=False
                assert after['sharing']==expected_sharing
            assert {k:after[k] for k in stable}=={k:initial[k] for k in stable}
            assert after['permanent_password_set'] and after['temporary_password'] is None
            assert 'CRITICAL' not in (output/f'gui-{index}.log').read_text()
            if os.environ.get('FARPANE_NATIVE_MEMORY_PROBE') in ('identity','mmap128k'):
                log=(output/f'gui-{index}.log').read_text()
                identity={key:re.findall(r'^FARPANE_GL_'+key+r'=(.+)$',log,re.M)
                          for key in ('VENDOR','RENDERER','VERSION')}
                assert all(len(values)==1 and values[0]!='unavailable' for values in identity.values()), identity
                (directory/'gl-identity.json').write_text(json.dumps({key:values[0] for key,values in identity.items()},indent=2))
            for stem in ['home','gui-pre-capture','home-pre-trim','viewer-pre-trim']:
                source=directory/f'{stem}-smaps.txt'
                if source.exists():
                    (directory/f'{stem}-pss-by-mapping.json').write_text(json.dumps(memory_breakdown(source.read_text()),indent=2))
            if gpu_test:
                sharing=json.loads((directory/'gl-sharing.json').read_text())
                assert sharing['shared'] and sharing['area_api']==sharing['display_api'], sharing
                assert report.get('gpu_frames',0)>0, 'Actual GTK Viewer did not import and draw DMA-BUF frames'
                media=[e['event']['data'] for e in report['events'] if e['event']['type']=='media']
                assert media and media[-1]['backend']=='vaapi', media
                assert report['frames']==report['gpu_frames'], 'GPU test silently used software frames'
            if input_test:
                events=(output/'pattern.log').read_bytes()[input_start:].decode(errors='replace')
                (directory/'remote-input-events.txt').write_text(events)
                assert 'KeyPress event' in events and 'KeyRelease event' in events and 'Control_L' in events, events
                assert 'keysym 0x61, a' in events, events
                assert '0x1004e2d' in events or '0x4e2d' in events or '中' in events, events
                assert events.count('ButtonPress event')==2, 'Local toolbar click escaped into remote input'
                presses=[event for event in events.split('\n\n') if event.startswith('KeyPress event')]
                assert sum('0x1004e2d' in e or '0x4e2d' in e for e in presses)==1, 'IME commit was duplicated'
                assert not any(re.search(r'keysym 0x(?:75|34|65|32|64),',e) for e in presses), 'IME preedit leaked to the peer'
        checks=['loopback-login','actual-video-decode',
            'gtk-presentation','viewer-exit-reaped','second-session','host-retained','host-media-auth-network-preserved','successful-session-history']
        if not secrets_locked and not secrets_unavailable:checks+=['wrong-password-retry']
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='audio':checks+=['real-opus-playback-440hz','disabled-no-tail','reenable','remote-audio-revocation','monitor-source-not-default-microphone','audio-service-failure-reported','video-refresh-after-audio-failure']
        if input_test:checks+=['actual-keyboard','actual-ime-single-commit','ime-preedit-kept-local','window-deactivation-release','disconnect-release','toolbar-click-kept-local']
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='clipboard':checks+=['text-clipboard-both-directions','clipboard-size-limit','clipboard-disable-stops-send']
        if gpu_test:checks+=['vaapi-worker','actual-gtk-dmabuf-render','private-xwayland' if xwayland else 'headless-wayland','no-software-frame-fallback']
        if retry_test:checks+=['private-worker-crash','actual-retry-button','same-gui-new-session','old-worker-reaped-before-retry']
        if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='cursor':checks+=['actual-native-cursor-colors','cursor-hotspot','cursor-cached-reselection','cursor-toolbar-boundary']
        if secrets_test:
            private_secrets.device_ui(start);private_secrets.report()
            checks+=['secret-service-store-after-auth','saved-password-load','stalled-keyring-cancel','manual-login-during-lookup','secret-forget','credential-scope-isolation','device-password-forget-confirmation','device-record-and-password-forget','remote-hostname-search']
        if secrets_unavailable:checks+=['keyring-unavailable-manual-login']
        if secrets_locked:
            private_secrets.verify_locked()
            checks+=['locked-keyring-no-unlock-prompt','locked-keyring-manual-login','locked-keyring-provider-alive']
        print(json.dumps({'result':'pass','checks':checks,
            'gpu':gpu_test,'network':'isolated-loopback','display':'private-headless-wayland-and-xvfb' if gpu_test else 'two-private-xvfb'}))
    finally:
        if private_secrets:private_secrets.resume()
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
        for log in logs: log.close()
        # Preserve only this isolated runtime's logs, including failed sessions.
        # Its synthetic credentials/configuration never come from the host.
        for source in RUNTIME.rglob('*.log'):
            target=output/'core-logs'/source.relative_to(RUNTIME)
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(source,target)


def setup(output, uid, gid):
    assert os.geteuid()==0 and Path('/.dockerenv').exists()
    # Create once as container root before two ordinary-user X servers race.
    x11 = Path('/tmp/.X11-unix'); x11.mkdir(exist_ok=True); x11.chmod(0o1777)
    stage_release()
    RUNTIME.mkdir(mode=0o700, parents=True); os.chown(RUNTIME, uid, gid)
    output.mkdir(parents=True); os.chown(output, uid, gid)
    # Tie each result to the exact private test executables, including failures.
    import hashlib
    binaries={str(p.relative_to(RELEASE)):hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
              for p in [RELEASE/'farpane',RELEASE/'libexec/farpane-core']}
    (output/'test-binaries.json').write_text(json.dumps(binaries,indent=2)+'\n')
    if os.environ.get('FARPANE_LIFECYCLE_OBJECTS')=='1':
        flags=subprocess.check_output(['pkg-config','--cflags','--libs','gobject-2.0'],text=True).split()
        subprocess.run(['cc','-std=c11','-shared','-fPIC','-O2','-Wall','-Wextra','-Werror',
                        '/workspace/Linux/tests/native_object_observer.c','-ldl','-pthread',*flags,
                        '-o',str(output/'object-observer.so')],check=True)
        os.chown(output/'object-observer.so',uid,gid)
    if os.environ.get('FARPANE_NATIVE_MEMORY_PROBE') in ('identity','mmap128k','allocations'):
        assert gpu_mode()
        subprocess.run(['cc','-std=c11','-shared','-fPIC','-O2','-Wall','-Wextra','-Werror',
                        '/workspace/Linux/tests/native_gl_identity.c','-lEGL','-lGLESv2','-ldl','-pthread',
                        '-o',str(output/'gl-identity.so')],check=True)
    if os.environ.get('FARPANE_NATIVE_MEMORY_PROBE') == 'allocations':
        assert gpu_mode() and os.environ.get('FARPANE_NATIVE_TEST_HOME_ONLY') == '1'
        subprocess.run(['cc','-std=c11','-shared','-fPIC','-O2','-Wall','-Wextra','-Werror',
                        '/workspace/Linux/tests/native_allocation_profile.c','-ldl','-pthread',
                        '-o',str(output/'allocation-profile.so')],check=True)
    if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='clipboard':
        subprocess.run(['cc','-std=c11','-D_POSIX_C_SOURCE=200809L','-Wall','-Wextra','-Werror','/workspace/Linux/tests/x11_clipboard_fixture.c','-lX11','-o',str(output/'clipboard-fixture')],check=True)
        os.chown(output/'clipboard-fixture',uid,gid)
    env = dict(os.environ, XDG_RUNTIME_DIR=str(RUNTIME), RUSTDESK_FORCED_DISPLAY_SERVER='x11', PYTHONDONTWRITEBYTECODE='1')
    for name, suffix in [('XDG_CONFIG_HOME','config'), ('XDG_DATA_HOME','data'), ('XDG_CACHE_HOME','cache'), ('XDG_STATE_HOME','state')]:
        directory=RUNTIME/suffix; directory.mkdir(mode=0o700); os.chown(directory, uid, gid); env[name]=str(directory)
    if os.environ.get('FARPANE_NATIVE_TEST_MODE')=='desktop':
        service=Path(env['XDG_DATA_HOME'])/'dbus-1/services/org.farpane.FarPane.service'
        service.parent.mkdir(parents=True)
        template=Path('/workspace/Linux/packaging/org.farpane.FarPane.service.in').read_text()
        service.write_text(template.replace('@FARPANE_RELEASE@',str(RELEASE)))
    groups=['--groups',str(Path('/dev/dri/renderD128').stat().st_gid)] if gpu_mode() else ['--clear-groups']
    result=subprocess.run(['setpriv','--reuid',str(uid),'--regid',str(gid),*groups,
        'dbus-run-session','--','python3','-B',__file__,'--user',str(output)], env=env)
    sys.exit(result.returncode)


if __name__=='__main__':
    if sys.argv[1]=='--user': user_test(Path(sys.argv[2]))
    else: setup(Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]))
