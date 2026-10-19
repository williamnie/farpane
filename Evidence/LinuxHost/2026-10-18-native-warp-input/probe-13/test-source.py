"""Inspect a fresh, offline Warp window in a private container, never the host."""
import json
import ctypes
import os
from pathlib import Path
import subprocess
import time
import traceback


def exercise():
    assert Path('/.dockerenv').is_file() and os.geteuid() == 1000
    assert not any(Path(p).exists() for p in ('/dev/dri', '/dev/uinput', '/dev/kvm'))
    assert not any(os.environ.get(k) for k in ('DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS'))
    assert os.environ['HOME'] == '/tmp/farpane-warp-home'
    output = Path('/output')
    home = Path(os.environ['HOME']);home.mkdir(mode=0o700)
    runtime = home/'runtime';runtime.mkdir(mode=0o700)
    env = dict(os.environ, DISPLAY=':89', XDG_RUNTIME_DIR=str(runtime),
               XDG_CONFIG_HOME=str(home/'config'), XDG_CACHE_HOME=str(home/'cache'),
               XDG_DATA_HOME=str(home/'data'), XDG_STATE_HOME=str(home/'state'),
               DBUS_SESSION_BUS_ADDRESS='unix:path='+str(runtime/'bus'),
               LIBGL_ALWAYS_SOFTWARE='1', GALLIUM_DRIVER='llvmpipe',
               WARP_ENABLE_WAYLAND='0', LANG='C.UTF-8')
    processes=[];logs=[];cases=[]
    def start(name, args):
        log=(output/(name+'.log')).open('w');logs.append(log)
        p=subprocess.Popen(args,env=env,stdout=log,stderr=subprocess.STDOUT)
        processes.append(p);return p
    try:
        xvfb=start('xvfb',['Xvfb',':89','-screen','0','1280x960x24','-nolisten','tcp','-ac'])
        bus=start('bus',['dbus-daemon','--session','--nofork','--address='+env['DBUS_SESSION_BUS_ADDRESS']])
        time.sleep(1)
        assert xvfb.poll() is None and bus.poll() is None
        warp=start('warp',['/opt/warpdotdev/warp-terminal/warp','--debug'])
        time.sleep(15)
        assert xvfb.poll() is None and bus.poll() is None
        os.environ.update(env)
        import gi
        gi.require_version('Gdk','3.0')
        gi.require_version('Gtk','3.0')
        from gi.repository import Gdk, Gtk, GLib
        root=Gdk.get_default_root_window()
        def screenshot(name):
            pixbuf=Gdk.pixbuf_get_from_window(root,0,0,1280,960)
            assert pixbuf is not None
            pixbuf.savev(str(output/name),'png',[],[])
        screenshot('window.png')
        if warp.poll() is None:
            # Owned Xvfb only, after checking its child is still alive. The
            # screenshot shows the fresh welcome screen's Get started button.
            x11=ctypes.CDLL('libX11.so.6');xtest=ctypes.CDLL('libXtst.so.6')
            x11.XOpenDisplay.argtypes=[ctypes.c_char_p];x11.XOpenDisplay.restype=ctypes.c_void_p
            x11.XFlush.argtypes=[ctypes.c_void_p];x11.XCloseDisplay.argtypes=[ctypes.c_void_p]
            x11.XStringToKeysym.argtypes=[ctypes.c_char_p];x11.XStringToKeysym.restype=ctypes.c_ulong
            x11.XKeysymToKeycode.argtypes=[ctypes.c_void_p,ctypes.c_ulong];x11.XKeysymToKeycode.restype=ctypes.c_uint
            x11.XGetInputFocus.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_ulong),ctypes.POINTER(ctypes.c_int)]
            x11.XSetInputFocus.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_int,ctypes.c_ulong]
            x11.XQueryTree.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.POINTER(ctypes.c_ulong),ctypes.POINTER(ctypes.c_ulong),ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)),ctypes.POINTER(ctypes.c_uint)]
            x11.XGetGeometry.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.POINTER(ctypes.c_ulong),ctypes.POINTER(ctypes.c_int),ctypes.POINTER(ctypes.c_int),ctypes.POINTER(ctypes.c_uint),ctypes.POINTER(ctypes.c_uint),ctypes.POINTER(ctypes.c_uint),ctypes.POINTER(ctypes.c_uint)]
            x11.XFree.argtypes=[ctypes.c_void_p]
            xtest.XTestFakeMotionEvent.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_ulong]
            xtest.XTestFakeButtonEvent.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_int,ctypes.c_ulong]
            xtest.XTestFakeKeyEvent.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_int,ctypes.c_ulong]
            display=x11.XOpenDisplay(b':89');assert display
            try:
                def click(x,y,name):
                    xtest.XTestFakeMotionEvent(display,-1,x,y,0)
                    xtest.XTestFakeButtonEvent(display,1,1,0)
                    xtest.XTestFakeButtonEvent(display,1,0,0);x11.XFlush(display)
                    time.sleep(3);screenshot(name)
                click(640,477,'after-get-started.png')
                # Reviewed private screenshot: customization step, defaults.
                click(478,736,'after-customization.png')
                # Reviewed private screenshot: retain the default dark theme.
                click(478,736,'after-theme.png')
                # Reviewed account page offers Skip: no account or credentials.
                click(382,736,'after-skip-account.png')
                click(780,459,'after-confirm-skip.png')
                click(360,758,'input-focused.png')
                def pump(seconds):
                    end=time.monotonic()+seconds
                    while time.monotonic()<end:
                        while GLib.MainContext.default().pending():GLib.MainContext.default().iteration(False)
                        time.sleep(.01)
                def chord(names):
                    codes=[x11.XKeysymToKeycode(display,x11.XStringToKeysym(n.encode())) for n in names]
                    assert all(codes)
                    for code in codes:xtest.XTestFakeKeyEvent(display,code,1,0);x11.XFlush(display);pump(.05)
                    for code in reversed(codes):xtest.XTestFakeKeyEvent(display,code,0,0);x11.XFlush(display);pump(.05)
                clipboard=Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
                primary=Gtk.Clipboard.get(Gdk.SELECTION_PRIMARY)
                def window_state(label):
                    focus=ctypes.c_ulong();revert=ctypes.c_int()
                    x11.XGetInputFocus(display,ctypes.byref(focus),ctypes.byref(revert))
                    parent=ctypes.c_ulong();root_id=ctypes.c_ulong();ids=ctypes.POINTER(ctypes.c_ulong)();count=ctypes.c_uint()
                    assert x11.XQueryTree(display,root.get_xid(),ctypes.byref(root_id),ctypes.byref(parent),ctypes.byref(ids),ctypes.byref(count))
                    children=[]
                    try:
                        for i in range(count.value):
                            x=ctypes.c_int();y=ctypes.c_int();w=ctypes.c_uint();h=ctypes.c_uint();border=ctypes.c_uint();depth=ctypes.c_uint()
                            if x11.XGetGeometry(display,ids[i],ctypes.byref(root_id),ctypes.byref(x),ctypes.byref(y),ctypes.byref(w),ctypes.byref(h),ctypes.byref(border),ctypes.byref(depth)):
                                children.append({'xid':ids[i],'geometry':[x.value,y.value,w.value,h.value]})
                    finally:x11.XFree(ids)
                    (output/(label+'-windows.json')).write_text(json.dumps({'focus':focus.value,'children':children}))
                    return children
                windows=window_state('before-paste')
                large=[w for w in windows if w['geometry'][2]>=1000 and w['geometry'][3]>=700]
                assert len(large)==1,windows
                x11.XSetInputFocus(display,large[0]['xid'],1,0);x11.XFlush(display)
                # Distinct selections tell us which one Warp actually pastes.
                primary.set_text("printf '%s' 'PRIMARY sentinel' > "+str(home/'primary-selection.txt'),-1)
                for label,keys in [('shift-insert',['Shift_L','Insert']),
                                   ('ctrl-shift-v',['Control_L','Shift_L','v'])]:
                    expected='中文测试混合A1，🙂é'
                    received=home/(label+'.txt')
                    clipboard.set_text("printf '%s' '"+expected+"' > "+str(received),-1)
                    pump(.3);chord(keys);pump(.5);screenshot(label+'-pasted.png')
                    chord(['Return']);pump(1.5);screenshot(label+'-submitted.png')
                    window_state(label)
                    actual=received.read_text() if received.exists() else None
                    cases.append({'name':label,'expected':expected,'actual':actual,
                        'primary_pasted':(home/'primary-selection.txt').exists(),
                        'result':'pass' if actual==expected else 'fail'})
            finally:x11.XCloseDisplay(display)
        (output/'report.json').write_text(json.dumps({'warp_exit_code':warp.poll(),
            'profile':'new-empty-private','network':'none','host_display_used':False,
            'input_tested':bool(cases),'input_scope':'local private X11 clipboard and keyboard; no FarPane network',
            'cases':cases},ensure_ascii=False,indent=2)+'\n')
        # Wrappers/config generated exclusively in this empty test profile.
        wrappers=list(home.rglob('warpctrl'))
        (output/'wrapper-discovery.json').write_text(json.dumps([
            {'path':str(p.relative_to(home)), 'text':p.read_text()}
            for p in wrappers if p.is_file() and p.stat().st_size<8192],indent=2))
    except Exception:
        (output/'failure.txt').write_text(traceback.format_exc())
        raise
    finally:
        def sanitized_log(path):
            return '\n'.join('[packaged OAuth/telemetry configuration omitted]' if 'ChannelState {' in line else line
                             for line in path.read_text(errors='replace').splitlines())[-60000:]
        (output/'private-log-files.json').write_text(json.dumps([
            {'path':str(p.relative_to(home)), 'text':sanitized_log(p)}
            for p in home.rglob('*.log') if p.is_file()],indent=2))
        for p in reversed(processes):
            if p.poll() is None:p.terminate()
        for p in processes:
            try:p.wait(timeout=3)
            except subprocess.TimeoutExpired:p.kill();p.wait(timeout=3)
        for log in logs:log.close()


if __name__=='__main__':exercise()
