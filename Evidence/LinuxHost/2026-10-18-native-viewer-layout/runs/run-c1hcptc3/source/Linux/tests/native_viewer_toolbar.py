"""Real external clicks, held-key release and fresh video across toolbar changes."""
import ctypes as C
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

from native_home_layout import guard, observe, click, settle, geometry
from native_host_smoke import RELEASE, cli
from native_lifecycle_smoke import Display, children


def exercise(output, start, agent, initial):
    guard()
    assert os.environ['FARPANE_NATIVE_TEST_MODE'] == 'viewer-toolbar'
    size=os.environ.get('FARPANE_VIEWER_LAYOUT_SIZE','1020x720')
    scale=int(os.environ.get('FARPANE_VIEWER_LAYOUT_SCALE','1'))
    assert size in ('1020x720','800x600') and scale in (1,2)
    width,height=map(int,size.split('x'));physical_width,physical_height=width*scale,height*scale
    directory = output/'layout-viewer'
    directory.mkdir(); (directory/'widgets').mkdir(mode=0o700)
    env = dict(os.environ, DISPLAY=':92', GSK_RENDERER='cairo', GTK_A11Y='none',
               GDK_SCALE=str(scale),
               LD_PRELOAD=str(output/'layout-widgets.so'),
               FARPANE_LAYOUT_WIDGET_DIR=str(directory/'widgets'))
    assert not any('SMOKE_DIR' in k or 'SMOKE_REPORT' in k or 'MEMORY_PROBE' in k for k in env)
    gui = start('toolbar-gui',[str(RELEASE/'farpane')],env)
    screen, remote = Display(':92'), Display(':91')
    screen.x.XResizeWindow.argtypes=[C.c_void_p,C.c_ulong,C.c_uint,C.c_uint]
    screen.x.XMoveWindow.argtypes=[C.c_void_p,C.c_ulong,C.c_int,C.c_int]
    remote.x.XQueryKeymap.argtypes = [C.c_void_p,C.c_void_p]
    remote.x.XQueryPointer.argtypes = [C.c_void_p,C.c_ulong,C.POINTER(C.c_ulong),C.POINTER(C.c_ulong),
        C.POINTER(C.c_int),C.POINTER(C.c_int),C.POINTER(C.c_int),C.POINTER(C.c_int),C.POINTER(C.c_uint)]
    pattern = remote.x.XCreateSimpleWindow(remote.display,remote.root,80,100,480,260,0,0,0x21906a)
    remote.x.XMapRaised(remote.display,pattern);remote.x.XSync(remote.display,0)
    def wait(predicate, message, seconds=20):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            assert gui.poll() is None and agent.poll() is None
            value=predicate()
            if value:return value
            time.sleep(.1)
        capture(directory/'failure.png')
        raise AssertionError(message)
    def window():
        tree=subprocess.check_output(['xwininfo','-display',':92','-root','-tree'],text=True)
        match=re.search(r'(0x[0-9a-f]+) "FarPane"',tree)
        return int(match[1],16) if match else 0
    def phase(name):
        rows=observe(directory,name,gui)
        capture(directory/(name+'.png'))
        assert {r['scale'] for r in rows}=={scale}
        return rows
    def capture(path=None):
        return screen.capture(path,width=physical_width,height=physical_height)
    def control_bounds(rows):
        for text in ('独占键盘','文件','HUD','诊断','断开并返回'):
            assert any(r.get('text')==text and r['inside_window'] for r in rows), ('Control is clipped',text)
        for widget_type in ('GtkDropDown','GtkMenuButton'):
            assert any(r['type']==widget_type and r['inside_window'] for r in rows), widget_type
    def remote_control():
        keys=(C.c_ubyte*32)()
        remote.x.XQueryKeymap(remote.display,keys)
        code=remote.x.XKeysymToKeycode(remote.display,0xffe3)
        return bool(keys[code//8] & (1<<(code%8)))
    def picture(rows):
        matches=[r for r in rows if r['type']=='GtkPicture']
        assert len(matches)==1
        return matches[0]['bounds']
    def reveal(rows):
        return [r for r in rows if r['name']=='viewer-toolbar' and r.get('reveal_child')]
    def color_points(color):
        raw,stride=capture()
        expected=(color>>16,(color>>8)&255,color&255)
        points=[]
        for y in range(50*scale,(height-35)*scale,4*scale):
            for x in range(10*scale,(width-10)*scale,4*scale):
                at=y*stride+x*4;b,g,r=raw[at:at+3]
                if all(abs(a-b)<=6 for a,b in zip((r,g,b),expected)):points.append((x,y))
        return points
    def pattern_point(color):
        points=color_points(color);assert len(points)>1000
        xs,ys=zip(*points)
        return [(min(xs)+max(xs))//2,(min(ys)+max(ys))//2]
    def verify_pointer(color):
        screen.click(pattern_point(color))
        def matches():
            root,child=C.c_ulong(),C.c_ulong();rx,ry,wx,wy=(C.c_int() for _ in range(4));mask=C.c_uint()
            remote.x.XQueryPointer(remote.display,remote.root,C.byref(root),C.byref(child),
                C.byref(rx),C.byref(ry),C.byref(wx),C.byref(wy),C.byref(mask))
            return abs(rx.value-320)<=4 and abs(ry.value-230)<=4
        wait(matches,'Pointer mapping changed after toolbar resize')
    checks=[]
    try:
        xid=wait(window,'GUI did not open');settle(gui,agent,3)
        screen.x.XMoveWindow(screen.display,xid,0,0)
        screen.x.XResizeWindow(screen.display,xid,physical_width,physical_height)
        screen.x.XFlush(screen.display);screen.focus(xid);settle(gui,agent)
        rows=phase('home')
        click(screen,rows,widget_type='GtkEntry');screen.type('127.0.0.1:21118');click(screen,rows,text='连接')
        workers=wait(lambda:children(gui.pid),'Worker did not start');assert len(workers)==1
        worker=workers[0];assert Path(f'/proc/{worker}/exe').resolve()==RELEASE/'libexec/farpane-core'
        settle(gui,agent,2);rows=phase('authentication')
        (directory/'viewer-wm-normal-hints.txt').write_text(subprocess.check_output(
            ['xprop','-display',':92','-id',str(xid),'WM_NORMAL_HINTS'],text=True))
        (directory/'viewer-geometry.json').write_text(json.dumps(geometry(xid))+'\n')
        control_bounds(rows)
        click(screen,rows,widget_type='GtkPasswordEntry');screen.type('native-viewer-smoke');click(screen,rows,text='验证并连接')
        wait(lambda:len(color_points(0x21906a))>1000,'Video did not appear',30)
        rows=phase('streaming');assert reveal(rows)
        control_bounds(rows)
        original_picture=picture(rows)
        # Send Control to the private remote X server before changing layout.
        screen.click(pattern_point(0x21906a));screen.key(0xffe3,True)
        wait(remote_control,'Held Control did not reach the remote')
        click(screen,rows,tooltip='收起工具栏');screen.key(0xffe3,False)
        wait(lambda:not remote_control(),'Control remained pressed after collapsing')
        settle(gui,agent);rows=phase('collapsed')
        assert not reveal(rows)
        collapsed_picture=picture(rows)
        assert collapsed_picture[3] > original_picture[3]+40
        assert not any(r.get('text')=='HUD' for r in rows)
        assert any(r.get('text')=='断开并返回' and r['inside_window'] for r in rows)
        assert children(gui.pid)==[worker]
        checks += ['held-key-released','toolbar-hidden','picture-expanded','disconnect-remains-visible']
        remote.x.XSetWindowBackground(remote.display,pattern,0x8030a0)
        remote.x.XClearWindow(remote.display,pattern);remote.x.XSync(remote.display,0)
        wait(lambda:len(color_points(0x8030a0))>1000,'Video stopped while collapsed')
        verify_pointer(0x8030a0)
        checks.append('fresh-video-while-collapsed')
        click(screen,rows,tooltip='展开工具栏');settle(gui,agent)
        rows=phase('restored');assert reveal(rows) and picture(rows)==original_picture
        control_bounds(rows)
        verify_pointer(0x8030a0)
        checks.append('expand-restores-layout')
        checks.append('pointer-mapping-after-both-resizes')
        click(screen,rows,tooltip='收起工具栏');settle(gui,agent)
        # Kill only this private, identity-checked child: local failure must
        # restore controls without affecting the independent private Host.
        assert Path(f'/proc/{worker}/exe').resolve()==RELEASE/'libexec/farpane-core'
        os.kill(worker,signal.SIGKILL)
        wait(lambda:not children(gui.pid) and not Path(f'/proc/{worker}').exists(),'Worker not reaped')
        settle(gui,agent);rows=phase('failed');assert reveal(rows)
        assert any(r.get('text')=='重新连接' and r['inside_window'] for r in rows)
        checks.append('worker-failure-reveals-retry')
        click(screen,rows,text='断开并返回');settle(gui,agent,2)
        rows=phase('disconnected')
        assert any(r.get('text')=='你的设备' for r in rows)
        wait(lambda:not cli({'type':'snapshot'})['inbound'],'Host retained ended session')
        after=cli({'type':'snapshot'})
        for key in ('local_id','server','authentication','host_enabled','gpu_enabled'):
            assert after[key]==initial[key],key
        assert agent.poll() is None and not children(gui.pid)
        checks.append('return-home-preserves-host')
        result={'result':'pass','checks':checks,'original_picture':original_picture,
                'logical_size':[width,height],'scale':scale,'physical_geometry':geometry(xid),
                'collapsed_picture':collapsed_picture,'software_only':True,'host_preserved':True,
                'real_desktop_tested':False,'chinese_input_tested':False,'memory_optimization':False}
        (output/'viewer-toolbar-result.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result),flush=True)
    finally:
        screen.key(0xffe3,False)
        if gui.poll() is None:gui.terminate()
        try:gui.wait(timeout=5)
        except subprocess.TimeoutExpired:gui.kill();gui.wait(timeout=5)
        remote.x.XDestroyWindow(remote.display,pattern)
        screen.close();remote.close()
