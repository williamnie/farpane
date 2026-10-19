"""Observe launch requests and drive GNOME's app search in the private VM."""
import ctypes as C
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import struct
import subprocess
import time
import zlib

from native_input_vm_desktop import OUTPUT, wait
from native_maintenance_vm import processes, require_maintenance


def require_probe():
    _, marker = require_maintenance()
    assert marker.get('desktop_launch_probe') is True or marker.get('desktop_lifecycle_probe') is True
    cards=list(Path('/sys/class/drm').glob('card[0-9]'))
    assert len(cards)==1 and cards[0].name=='card0' and (cards[0]/'device').resolve().name=='vkms'


def capture(release, name):
    require_probe()
    assert re.fullmatch('launch-[a-z0-9-]+',name)
    class Config(C.Structure):
        _fields_=[('device',C.c_char_p),('crtc',C.c_uint32),('helper',C.c_char_p),('debug',C.c_int)]
    class Frame(C.Structure):
        _fields_=[('data',C.c_void_p),('fd',C.c_int),('width',C.c_uint32),('height',C.c_uint32),
                  ('stride',C.c_uint32),('format',C.c_uint32),('modifier',C.c_uint64),
                  ('fb_id',C.c_uint32),('private',C.c_void_p)]
    library=Path('/opt/farpane/releases')/release/'lib/libdrmtap.so.0'
    lib=C.CDLL(str(library))
    assert lib.drmtap_version()==0x0508
    lib.drmtap_open.argtypes=[C.POINTER(Config)];lib.drmtap_open.restype=C.c_void_p
    lib.drmtap_grab_mapped.argtypes=[C.c_void_p,C.POINTER(Frame)];lib.drmtap_grab_mapped.restype=C.c_int
    lib.drmtap_frame_release.argtypes=[C.c_void_p,C.POINTER(Frame)]
    lib.drmtap_close.argtypes=[C.c_void_p]
    context=lib.drmtap_open(C.byref(Config(b'/dev/dri/card0',0,None,0)))
    assert context,'Guest VKMS capture unavailable'
    frame=Frame()
    try:
        assert lib.drmtap_grab_mapped(context,C.byref(frame))==0
        assert frame.data and 1<=frame.width<=2560 and 1<=frame.height<=1600
        assert frame.width*4<=frame.stride<=frame.width*4+4096
        fmt=frame.format.to_bytes(4,'little')
        assert fmt in (b'XR24',b'AR24',b'XB24',b'AB24'),fmt
        raw=C.string_at(frame.data,frame.stride*frame.height)
        rows=bytearray()
        for y in range(frame.height):
            row=raw[y*frame.stride:y*frame.stride+frame.width*4]
            rgb=bytearray(frame.width*3)
            r,b=(2,0) if fmt in (b'XR24',b'AR24') else (0,2)
            rgb[0::3],rgb[1::3],rgb[2::3]=row[r::4],row[1::4],row[b::4]
            rows.append(0);rows.extend(rgb)
        def chunk(kind,data):
            return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data))
        png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',frame.width,frame.height,8,2,0,0,0))
        png+=chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b'')
        assert len(png)<=1024*1024
        (OUTPUT/(name+'.png')).write_bytes(png)
        return {'file':name+'.png','width':frame.width,'height':frame.height,'format':fmt.decode(),
                'sha256':hashlib.sha256(png).hexdigest(),'capture':'guest-only VKMS mapped frame'}
    finally:
        lib.drmtap_frame_release(context,C.byref(frame));lib.drmtap_close(context)


class Keyboard:
    def __init__(self,gnome_pid):
        require_probe()
        self.fd=os.open('/dev/uinput',os.O_WRONLY|os.O_NONBLOCK|os.O_CLOEXEC)
        self.created=False
        try:
            fcntl.ioctl(self.fd,0x40045564,1)
            for code in range(1,256):fcntl.ioctl(self.fd,0x40045565,code)
            name='FarPane private desktop launcher'
            fcntl.ioctl(self.fd,0x405c5503,struct.pack('HHHH80sI',3,0x1234,2,1,name.encode(),0))
            fcntl.ioctl(self.fd,0x5501);self.created=True
            def consumed():
                devices=[p for p in Path('/sys/class/input').glob('event*') if (p/'device/name').read_text().strip()==name]
                if len(devices)!=1:return False
                node='/dev/input/'+devices[0].name
                for path in Path('/proc',str(gnome_pid),'fd').iterdir():
                    try:
                        if str(path.readlink())==node:return node
                    except FileNotFoundError:pass
                return False
            self.device=wait(consumed,'GNOME did not open the private launcher keyboard',8)
        except BaseException:
            self.close();raise
    def _send(self,code,value):
        assert code in (1,125,33,30,19,25,49,18,28,56,15,62) and value in (0,1)
        payload=struct.pack('llHHi',0,0,1,code,value)+struct.pack('llHHi',0,0,0,0,0)
        assert os.write(self.fd,payload)==len(payload)
        time.sleep(.03)
    def key(self,code):
        self._send(code,1);self._send(code,0)
    def alt_key(self,code,while_held=None):
        assert code in (15,62)
        self._send(56,1)
        try:
            self.key(code)
            if while_held:
                time.sleep(.4);while_held()
        finally:self._send(56,0)
    def close(self):
        if self.created:fcntl.ioctl(self.fd,0x5502);self.created=False
        os.close(self.fd)


def exercise(env,release,gnome_pid):
    require_probe()  # Before capture, keyboard, process control or D-Bus access.
    _, marker = require_maintenance()
    assert marker.get('desktop_launch_probe') is True
    transport = marker.get('desktop_launch_transport', 'original')
    assert transport in ('original', 'exec')
    index_settle = marker.get('desktop_index_settle_seconds', 0)
    assert index_settle in (0, 7)
    prefix=['setpriv','--reuid=1000','--regid=1000','--clear-groups']
    desktop=Path(env['XDG_DATA_HOME'])/'applications/org.farpane.FarPane.desktop'
    assert desktop.is_file() and desktop.stat().st_uid==1000
    assert str(Path('/opt/farpane/releases')/release/'farpane') in desktop.read_text()
    original_desktop=desktop.read_bytes()
    require_all = transport=='exec' or b'DBusActivatable=false\n' in original_desktop
    desktop_comparison={'transport':transport,'original_sha256':hashlib.sha256(original_desktop).hexdigest(),
                        'temporary_user_entry_only':transport=='exec'}
    stable=[p for p in processes(release) if p['role'] in ('--service','--server')]
    assert len(stable)==2
    def user(args,timeout=10):
        return subprocess.run(prefix+list(map(str,args)),env=env,capture_output=True,text=True,timeout=timeout)
    def launcher(args, name):
        # Exec children inherit stdout/stderr. A pipe would make communicate()
        # wait for the GUI's lifetime, even when gio itself has already exited.
        path=OUTPUT/('desktop-launch-trace-command-'+name+'.log')
        with path.open('w') as log:
            done=subprocess.run(prefix+list(map(str,args)),env={**env,'G_DBUS_DEBUG':'message','WAYLAND_DEBUG':'client'},
                                stdout=log,stderr=subprocess.STDOUT,timeout=10)
        return {'exit':done.returncode,'output_file':path.name}
    def owner():
        response=user(['gdbus','call','--session','--dest','org.freedesktop.DBus',
            '--object-path','/org/freedesktop/DBus','--method',
            'org.freedesktop.DBus.GetConnectionUnixProcessID','org.farpane.FarPane'])
        if response.returncode:
            assert 'NameHasNoOwner' in response.stderr,response.stderr
            return None
        match=re.fullmatch(r'\(uint32 ([0-9]+),\)\s*',response.stdout)
        assert match,response.stdout
        return int(match[1])
    def stop_gui():
        for process in processes(release):
            if process['role']!='gui':continue
            pid=process['pid'];fd=os.pidfd_open(pid)
            try:
                assert process in processes(release)
                signal.pidfd_send_signal(fd,signal.SIGTERM)
                poll=select.poll();poll.register(fd,select.POLLIN)
                assert poll.poll(5000),'Private GUI did not terminate'
            finally:os.close(fd)
        wait(lambda:owner() is None,'Private GUI retained bus name',5)
    def case(name,launch,*,cold=True):
        if cold:stop_gui()
        began=time.monotonic();rows=[];last=None
        launch_result=launch()
        while time.monotonic()-began<16:
            now=time.monotonic()-began
            guis=[p for p in processes(release) if p['role']=='gui']
            bus_pid=owner()
            value={'gui':guis,'bus_pid':bus_pid}
            if value!=last:rows.append({'seconds':round(now,3),**value});last=value
            time.sleep(.15)
        screenshot=capture(release,'launch-'+name)
        alive=bool(last['gui']) and last['bus_pid'] in [p['pid'] for p in last['gui']]
        assert [p for p in processes(release) if p['role'] in ('--service','--server')]==stable
        pids=sorted({p['pid'] for row in rows for p in row['gui']})
        trace=subprocess.run(['journalctl','-b','--no-pager','-o','cat',
                              *['_PID='+str(pid) for pid in pids]],
                             capture_output=True,text=True,timeout=5)
        assert pids and trace.returncode==0
        trace_file='desktop-launch-trace-'+name+'.log'
        (OUTPUT/trace_file).write_text(trace.stdout)
        assert len(trace.stdout.encode())<=200000,'Guest activation trace exceeded export bound'
        # Exec inherits the launcher log; D-Bus activation writes its own
        # journal. Record compositor identity separately from the bus owner.
        identity=None
        if cold and name!='menu':
            source=launch_result.get('output_file',trace_file)
            contents=(OUTPUT/source).read_text()
            app_ids=re.findall(r'xdg_toplevel#[0-9]+\.set_app_id\("([^"]*)"\)',contents)
            titles=re.findall(r'xdg_toplevel#[0-9]+\.set_title\("([^"]*)"\)',contents)
            identity={'source':source,'app_ids':app_ids,'titles':titles}
            if alive or require_all:
                assert app_ids==['org.farpane.FarPane'],identity
                assert 'FarPane' in titles,identity
        return {'method':name,'cold':cold,'launch':launch_result,'timeline':rows,
                'gui_alive_at_16_seconds':alive,'capture':screenshot,'gui_dbus_trace':trace_file,
                'wayland_identity':identity}
    # Diagnostic environment for D-Bus children in this private session only.
    # The installed application, .desktop and .service files remain byte-exact.
    tracing=user(['gdbus','call','--session','--dest','org.freedesktop.DBus',
                  '--object-path','/org/freedesktop/DBus','--method',
                  'org.freedesktop.DBus.UpdateActivationEnvironment',
                  "{'G_DBUS_DEBUG': 'message', 'WAYLAND_DEBUG': 'client'}"])
    assert tracing.returncode==0,tracing.stderr
    monitor_log=(OUTPUT/'desktop-launch-bus.log').open('w')
    monitor=subprocess.Popen(prefix+['dbus-monitor','--session',
        "type='method_call',interface='org.freedesktop.Application'",
        "type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.farpane.FarPane'"],
        env=env,stdout=monitor_log,stderr=subprocess.STDOUT)
    reports=[];pictures=[]
    try:
        if transport=='exec':
            assert original_desktop.count(b'DBusActivatable=true\n')==1
            desktop.write_bytes(original_desktop.replace(b'DBusActivatable=true\n',b'DBusActivatable=false\n'))
        desktop_comparison['tested_sha256']=hashlib.sha256(desktop.read_bytes()).hexdigest()
        # Explicit diagnostic input, never an application/installer delay.
        if index_settle:time.sleep(index_settle)
        time.sleep(.2);assert monitor.poll() is None
        pictures.append(capture(release,'launch-before'))
        def cli():
            return launcher(['gio','launch',desktop],'cli')
        reports.append(case('cli',cli))
        def dbus():
            p=user(['gdbus','call','--session','--dest','org.farpane.FarPane',
                    '--object-path','/org/farpane/FarPane','--method',
                    'org.freedesktop.Application.Activate','{}'])
            return {'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr}
        reports.append(case('dbus',dbus))
        assert reports[-1]['gui_alive_at_16_seconds'],'Explicit D-Bus activation failed'
        # Same cold Exec path as the first case, after time has passed. No
        # desktop/icon/cache writes: compare the overview's app association.
        reports.append(case('cli-late',lambda:launcher(['gio','launch',desktop],'cli-late')))
        def gio():
            script="""import gi,sys,time
from gi.repository import Gio,GLib
app=Gio.DesktopAppInfo.new_from_filename(sys.argv[1]);assert app
assert app.launch([],None)
bus=Gio.bus_get_sync(Gio.BusType.SESSION,None);bus.flush_sync(None)
context=GLib.MainContext.default();end=time.monotonic()+2
while time.monotonic()<end:
 while context.pending():context.iteration(False)
 time.sleep(.01)
bus.flush_sync(None)
"""
            return launcher(['python3','-c',script,desktop],'gio')
        reports.append(case('gio',gio))
        warm=[p for p in processes(release) if p['role']=='gui']
        assert warm,'GIO event-loop launcher did not leave an active GUI'
        reports.append(case('cli-warm',lambda:launcher(['gio','launch',desktop],'cli-warm'),cold=False))
        assert [p for p in processes(release) if p['role']=='gui']==warm
        def menu():
            keyboard=Keyboard(gnome_pid)
            try:
                keyboard.key(1);time.sleep(.2)  # Close any initial overview.
                keyboard.key(125);time.sleep(.5)
                for code in (33,30,19,25,30,49,18):keyboard.key(code)  # farpane
                time.sleep(1)
                pictures.append(capture(release,'launch-search'))
                keyboard.key(28)
                return {'input_device':keyboard.device,'action':'GNOME overview search farpane, Enter'}
            finally:keyboard.close()
        reports.append(case('menu',menu))
        assert reports[-1]['gui_alive_at_16_seconds'],'GNOME application search did not launch FarPane'
        if require_all:
            assert all(row['gui_alive_at_16_seconds'] for row in reports),'Exec comparison failed a launch method'
        assert all(row['launch'].get('exit',0)==0 for row in reports),'Launcher command failed'
        return {'result':'pass','methods':reports,'extra_captures':pictures,'host_generation_unchanged':True,
                'desktop_comparison':desktop_comparison,
                'first_launch_delay_seconds':index_settle,
                'all_launch_methods_required':require_all,
                'chinese_input_tested':False,'screen':'private GNOME/VKMS; no host desktop',
                'diagnostic_activation_environment':{'G_DBUS_DEBUG':'message','WAYLAND_DEBUG':'client'},
                'cli_or_gio_failure_is_recorded_not_reclassified':True}
    finally:
        if transport=='exec':desktop.write_bytes(original_desktop)
        assert desktop.read_bytes()==original_desktop
        desktop_comparison['original_user_entry_restored']=True
        (OUTPUT/'desktop-launch-observations.log').write_text(json.dumps({'methods':reports,'extra_captures':pictures,
                                                                       'desktop_comparison':desktop_comparison},indent=2))
        monitor.terminate();monitor.wait(timeout=5);monitor_log.close()
        cleared=user(['gdbus','call','--session','--dest','org.freedesktop.DBus',
                      '--object-path','/org/freedesktop/DBus','--method',
                      'org.freedesktop.DBus.UpdateActivationEnvironment',
                      "{'G_DBUS_DEBUG': '', 'WAYLAND_DEBUG': ''}"])
        assert cleared.returncode==0,cleared.stderr
