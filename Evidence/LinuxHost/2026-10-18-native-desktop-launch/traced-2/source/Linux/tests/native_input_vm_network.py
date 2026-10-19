"""Packaged GTK Viewer -> TCP -> Host -> root uinput -> native Wayland target."""
import ctypes
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import time

from native_input_vm_desktop import OUTPUT, require_guest, wait


def exercise(core, env, account, device):
    require_guest()
    assert os.geteuid()==0
    # The already booted systemd/GNOME session is real. This marker enables
    # the unchanged packaged GUI's explicit smoke driver, not isolation.
    Path('/.dockerenv').touch()
    directory=OUTPUT/'viewer';directory.mkdir()
    os.chown(directory,1000,account.pw_gid)
    gui_env=dict(env,DISPLAY=':92',GDK_BACKEND='x11',XDG_SESSION_TYPE='x11',
                 FARPANE_VIEWER_SMOKE_DIR=str(directory),FARPANE_NATIVE_TEST_MODE='input',
                 GTK_IM_MODULE='gtk-im-context-simple',LIBGL_ALWAYS_SOFTWARE='1')
    for key in ('XAUTHORITY','WAYLAND_DISPLAY','XDG_SESSION_ID'):gui_env.pop(key,None)
    children=[];logs=[]
    def launch(name,args):
        log=(OUTPUT/(name+'.log')).open('w');logs.append(log)
        p=subprocess.Popen(['setpriv','--reuid=1000','--regid='+str(account.pw_gid),
                            '--clear-groups',*map(str,args)],env=gui_env,
                           stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
        children.append(p);return p
    target=json.loads(Path('/.farpane-input-vm').read_text())['target']
    text='中文测试'
    report={'result':'fail','text':text,'transport':'packaged-GTK-Viewer/TCP-loopback',
            'input_backend':'product-root-uinput','target':'native-Wayland-'+target,
            'device':device,'events':[]}
    fd=os.open(device,os.O_RDONLY|os.O_NONBLOCK|os.O_CLOEXEC)  # no grab
    def drain():
        size=struct.calcsize('llHHi')
        while True:
            try:data=os.read(fd,65536)
            except BlockingIOError:break
            assert len(data)%size==0
            report['events'].extend(list(struct.unpack('llHHi',data[i:i+size])[2:])
                                    for i in range(0,len(data),size))
    try:
        launch('viewer-display',['Xvfb',':92','-screen','0','1020x720x24','-nolisten','tcp'])
        wait(lambda:Path('/tmp/.X11-unix/X92').is_socket(),'Private Viewer Xvfb did not start')
        gui=launch('viewer',[core.parent.parent/'farpane'])
        def presented():
            path=directory/'viewer-progress.json'
            if path.exists():
                try:value=json.loads(path.read_text())
                except json.JSONDecodeError:return None
                report['viewer_phase']=value['phase']
                assert value['phase'] not in ('failed','closed'),value
                # The event-driven progress file may predate the first paint.
                # input-targets is written only after an actual painted frame.
                if value.get('presented') or (directory/'input-targets.json').exists():
                    return dict(value,presented=True)
            assert gui.poll() is None,'Private Viewer exited before frame'
        progress=wait(presented,'Private Viewer did not receive a frame',25)
        report['viewer_presented']=progress['presented']
        report['target_before']=json.loads((OUTPUT/'entry.json').read_text())
        # XTEST only drives the local client Xvfb. All remote keys below go
        # through the actual Viewer protocol, authenticated network and Host.
        x=ctypes.CDLL('libX11.so.6');t=ctypes.CDLL('libXtst.so.6')
        x.XOpenDisplay.argtypes=[ctypes.c_char_p];x.XOpenDisplay.restype=ctypes.c_void_p
        x.XKeysymToKeycode.argtypes=[ctypes.c_void_p,ctypes.c_ulong];x.XKeysymToKeycode.restype=ctypes.c_uint
        x.XSetInputFocus.argtypes=[ctypes.c_void_p,ctypes.c_ulong,ctypes.c_int,ctypes.c_ulong]
        x.XFlush.argtypes=[ctypes.c_void_p];x.XCloseDisplay.argtypes=[ctypes.c_void_p]
        t.XTestFakeKeyEvent.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_int,ctypes.c_ulong]
        t.XTestFakeMotionEvent.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.c_ulong]
        t.XTestFakeButtonEvent.argtypes=[ctypes.c_void_p,ctypes.c_uint,ctypes.c_int,ctypes.c_ulong]
        display=x.XOpenDisplay(b':92');assert display
        try:
            tree=subprocess.check_output(['xwininfo','-display',':92','-root','-tree'],text=True)
            window=re.search(r'(0x[0-9a-f]+) "FarPane"',tree);assert window,tree
            x.XSetInputFocus(display,int(window[1],16),2,0);x.XFlush(display)
            def key(symbol,down):
                code=x.XKeysymToKeycode(display,symbol);assert code
                t.XTestFakeKeyEvent(display,code,int(down),0);x.XFlush(display);time.sleep(.06)
                drain()
            t.XTestFakeMotionEvent(display,-1,510,380,0)
            t.XTestFakeButtonEvent(display,1,1,0);t.XTestFakeButtonEvent(display,1,0,0)
            x.XFlush(display);time.sleep(.2)
            # Focus the sole remote test window through the product too.
            key(0xffe9,True);key(0xff09,True);key(0xff09,False);key(0xffe9,False)
            def focused():
                state=json.loads((OUTPUT/'entry.json').read_text())
                report['target_focus']=state
                return state['active'] and state['focused']
            wait(focused,'Remote target did not receive focus',2)
            for char in text:
                key(0xffe3,True);key(0xffe1,True);key(ord('u'),True);key(ord('u'),False)
                key(0xffe1,False);key(0xffe3,False)
                for letter in format(ord(char),'x'):key(ord(letter),True);key(ord(letter),False)
                key(0xff0d,True);key(0xff0d,False)
            def received():
                drain()
                state=json.loads((OUTPUT/'entry.json').read_text())
                report['target_after']=state
                return state['text']==text
            wait(received,'Committed Chinese did not reach the native Wayland entry',3)
            time.sleep(.2)
            assert received(),'Committed text changed or was duplicated'
            keys=[e for e in report['events'] if e[0]==1]
            assert [0,3,0] not in report['events'],'The evdev observer lost events (SYN_DROPPED)'
            expected=[[1,42,1],[1,110,1],[1,110,0],[1,42,0]]
            assert sum(keys[i:i+4]==expected for i in range(len(keys)-3))==len(text),keys
            report['result']='pass'
        finally:x.XCloseDisplay(display)
        return report
    finally:
        drain();os.close(fd)
        (OUTPUT/'network-input.json').write_text(json.dumps(report))
        for child in reversed(children):
            if child.poll() is None:child.terminate()
            try:child.wait(timeout=3)
            except subprocess.TimeoutExpired:child.kill();child.wait(timeout=3)
        for log in logs:log.close()
