"""Real external clicks, held-key release and fresh video across toolbar changes."""
import ctypes as C
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

from native_home_layout import guard, observe, click, settle
from native_host_smoke import RELEASE, cli
from native_lifecycle_smoke import Display, children, colored_pixels


def exercise(output, start, agent, initial):
    guard()
    assert os.environ['FARPANE_NATIVE_TEST_MODE'] == 'viewer-toolbar'
    directory = output/'layout-viewer'
    directory.mkdir(); (directory/'widgets').mkdir(mode=0o700)
    env = dict(os.environ, DISPLAY=':92', GSK_RENDERER='cairo', GTK_A11Y='none',
               LD_PRELOAD=str(output/'layout-widgets.so'),
               FARPANE_LAYOUT_WIDGET_DIR=str(directory/'widgets'))
    assert not any('SMOKE_DIR' in k or 'SMOKE_REPORT' in k or 'MEMORY_PROBE' in k for k in env)
    gui = start('toolbar-gui',[str(RELEASE/'farpane')],env)
    screen, remote = Display(':92'), Display(':91')
    remote.x.XQueryKeymap.argtypes = [C.c_void_p,C.c_void_p]
    pattern = remote.x.XCreateSimpleWindow(remote.display,remote.root,80,100,480,260,0,0,0x21906a)
    remote.x.XMapRaised(remote.display,pattern);remote.x.XSync(remote.display,0)
    def wait(predicate, message, seconds=20):
        end=time.monotonic()+seconds
        while time.monotonic()<end:
            assert gui.poll() is None and agent.poll() is None
            value=predicate()
            if value:return value
            time.sleep(.1)
        screen.capture(directory/'failure.png')
        raise AssertionError(message)
    def window():
        tree=subprocess.check_output(['xwininfo','-display',':92','-root','-tree'],text=True)
        match=re.search(r'(0x[0-9a-f]+) "FarPane"',tree)
        return int(match[1],16) if match else 0
    def phase(name):
        rows=observe(directory,name,gui)
        screen.capture(directory/(name+'.png'))
        return rows
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
    checks=[]
    try:
        xid=wait(window,'GUI did not open');settle(gui,agent,3);screen.focus(xid)
        phase('home')
        layout=json.loads(Path('/workspace/Linux/tests/native-lifecycle-layout.json').read_text())
        screen.click(layout['peer']);screen.type('127.0.0.1:21118');screen.click(layout['connect'])
        workers=wait(lambda:children(gui.pid),'Worker did not start');assert len(workers)==1
        worker=workers[0];assert Path(f'/proc/{worker}/exe').resolve()==RELEASE/'libexec/farpane-core'
        settle(gui,agent,2);phase('authentication')
        screen.click(layout['password']);screen.type('native-viewer-smoke');screen.click(layout['authenticate'])
        wait(lambda:colored_pixels(screen.capture(),0x21906a)>15000,'Video did not appear',30)
        rows=phase('streaming');assert reveal(rows)
        original_picture=picture(rows)
        # Send Control to the private remote X server before changing layout.
        screen.click([510,420]);screen.key(0xffe3,True)
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
        wait(lambda:colored_pixels(screen.capture(),0x8030a0)>15000,'Video stopped while collapsed')
        checks.append('fresh-video-while-collapsed')
        click(screen,rows,tooltip='展开工具栏');settle(gui,agent)
        rows=phase('restored');assert reveal(rows) and picture(rows)==original_picture
        checks.append('expand-restores-layout')
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
