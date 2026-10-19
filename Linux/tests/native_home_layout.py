"""External pointer navigation and read-only GTK geometry; no resource tuning."""
import ctypes as C
import json
import os
from pathlib import Path
import re
import subprocess
import time

from native_host_smoke import RELEASE, cli
from native_lifecycle_smoke import Display


def guard():
    if (not Path('/.dockerenv').is_file() or os.geteuid() == 0
            or os.environ.get('FARPANE_NATIVE_TEST_MODE') not in ('home-layout', 'viewer-toolbar')
            or os.environ.get('HOME') != '/run/farpane-native-test/user'
            or os.environ.get('XDG_RUNTIME_DIR') != '/run/farpane-native-test/user'
            or any(Path(p).exists() for p in ('/dev/dri', '/dev/input', '/dev/uinput', '/dev/kvm'))
            or os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY')
            or os.environ.get('FONTCONFIG_FILE') or os.environ.get('LD_PRELOAD')):
        raise ValueError('Requires the marked private software-only layout test')


def settle(gui, agent, seconds=1):
    end = time.monotonic()+seconds
    while time.monotonic() < end:
        assert gui.poll() is None and agent.poll() is None
        time.sleep(.05)


def observe(directory, phase, gui):
    (directory/'widgets/request').write_text(phase)
    path = directory/'widgets'/(phase+'.json')
    end = time.monotonic()+5
    while True:
        assert gui.poll() is None and time.monotonic() < end, 'GTK layout observation timed out'
        try: data = json.loads(path.read_text())
        except (FileNotFoundError, json.JSONDecodeError): time.sleep(.05); continue
        assert data['widgets'] and not data['truncated']
        return data['widgets']


def geometry(xid):
    raw = subprocess.check_output(['xwininfo','-display',':92','-id',str(xid)],text=True)
    def value(label): return int(re.search(re.escape(label)+r':\s*(-?\d+)',raw)[1])
    return [value('Absolute upper-left X'),value('Absolute upper-left Y'),value('Width'),value('Height')]


def click(screen, rows, *, text=None, tooltip=None, widget_type=None, sidebar=False):
    matches = [r for r in rows if r['inside_window']
               and (text is None or r.get('text') == text)
               and (tooltip is None or r.get('tooltip') == tooltip)
               and (widget_type is None or r['type'] == widget_type)
               and (not sidebar or r['bounds'][0] < 180)]
    assert len(matches)==1, ('Ambiguous/missing visible control',text,tooltip,matches)
    row = matches[0]
    x,y,w,h = row['bounds']; origin = geometry(row['surface_xid'])
    point = [round(origin[0]+(x+w/2)*row['scale']),round(origin[1]+(y+h/2)*row['scale'])]
    assert 0 <= point[0] < 2560 and 0 <= point[1] < 1600
    screen.click(point)


def exercise(output, start, agent, initial):
    guard()
    screen = Display(':92')
    screen.x.XResizeWindow.argtypes = [C.c_void_p,C.c_ulong,C.c_uint,C.c_uint]
    screen.x.XMoveWindow.argtypes = [C.c_void_p,C.c_ulong,C.c_int,C.c_int]
    records = []
    try:
        for scale,width,height in [(1,1020,720),(1,800,600),(2,1020,720),(2,800,600)]:
            name=f'layout-{scale}x-{width}x{height}'
            directory=output/name;directory.mkdir();(directory/'widgets').mkdir(mode=0o700)
            env=dict(os.environ,DISPLAY=':92',GDK_SCALE=str(scale),GSK_RENDERER='gl',
                     GTK_A11Y='none',LIBGL_ALWAYS_SOFTWARE='1',GALLIUM_DRIVER='llvmpipe',
                     LD_PRELOAD=str(output/'layout-widgets.so'),
                     FARPANE_LAYOUT_WIDGET_DIR=str(directory/'widgets'))
            assert not any('SMOKE_DIR' in k or 'SMOKE_REPORT' in k or 'MEMORY_PROBE' in k for k in env)
            gui=start(name,[str(RELEASE/'farpane')],env)
            record={'scale':scale,'requested_logical_size':[width,height],'pages':[]}
            try:
                settle(gui,agent,3)
                tree=subprocess.check_output(['xwininfo','-display',':92','-root','-tree'],text=True)
                matches=re.findall(r'(0x[0-9a-f]+) "FarPane"',tree)
                assert len(matches)==1,tree
                xid=int(matches[0],16)
                hints=subprocess.check_output(['xprop','-display',':92','-id',str(xid),'WM_NORMAL_HINTS'],text=True)
                (directory/'wm-normal-hints.txt').write_text(hints)
                screen.x.XMoveWindow(screen.display,xid,0,0)
                screen.x.XResizeWindow(screen.display,xid,width*scale,height*scale)
                screen.x.XFlush(screen.display);screen.focus(xid);settle(gui,agent)
                record['actual_physical_geometry']=geometry(xid)
                def phase(key, expected=None):
                    rows=observe(directory,key,gui)
                    screen.capture(directory/(key+'.png'),width=width*scale,height=height*scale)
                    if expected:
                        assert any(r.get('text')==expected and r['inside_window'] for r in rows), (key,expected)
                    assert {r['scale'] for r in rows}=={scale}
                    record['pages'].append({'phase':key,'observed_widgets':len(rows),
                        'outside_window':sum(not r['inside_window'] for r in rows),
                        'ellipsized_labels':[r['text'] for r in rows if r.get('ellipsized')],
                        'root_sizes':sorted({tuple(r['root_size']) for r in rows})})
                    return rows
                rows=phase('home','你的设备')
                version_file=RELEASE/'release-info.json'
                if version_file.is_file():
                    version=json.loads(version_file.read_text())
                    assert any(r.get('text') == 'Linux · v'+version['version']
                               and r['inside_window'] and not r.get('ellipsized') for r in rows), 'Installed version is not fully visible'
                    assert any(r.get('text') == '主机核心 '+version['core_sha256'][:8]
                               and r['inside_window'] and not r.get('ellipsized') for r in rows), 'Installed core build is not fully visible'
                    record['visible_version']=version['version']
                    record['visible_core_build']=version['core_sha256'][:8]
                click(screen,rows,text='授权与安全',sidebar=True);settle(gui,agent)
                rows=phase('security','连接认证')
                click(screen,rows,text='共享设置',sidebar=True);settle(gui,agent)
                rows=phase('sharing','媒体与诊断')
                click(screen,rows,tooltip='服务器设置');settle(gui,agent)
                rows=phase('server','ID 服务器')
                assert any(r.get('text')=='保存设置' and r['inside_window'] for r in rows)
                screen.key(0xff1b,True);screen.key(0xff1b,False);settle(gui,agent)
                rows=phase('returned')
                click(screen,rows,text='设备',sidebar=True);settle(gui,agent)
                screen.t.XTestFakeMotionEvent(screen.display,-1,(width-8)*scale,(height-100)*scale,0)
                for _ in range(30):
                    screen.t.XTestFakeButtonEvent(screen.display,5,1,0)
                    screen.t.XTestFakeButtonEvent(screen.display,5,0,0)
                    screen.x.XFlush(screen.display);time.sleep(.01)
                settle(gui,agent)
                rows=phase('footer','最近设备')
                click(screen,rows,text='关于 FarPane',sidebar=True);settle(gui,agent)
                # libadwaita places comments on its Details subpage. The first
                # About page shows the application name and version instead.
                rows=phase('about')
                assert any(r['inside_window'] and re.fullmatch(r'\d+\.\d+\.\d+(?:[-+].*)?',
                           r.get('text','')) for r in rows), 'About version is not visible'
                after=cli({'type':'snapshot'})
                for key in ('local_id','server','revision','host_enabled','gpu_enabled','inbound'):
                    assert after[key]==initial[key],key
                assert 'CRITICAL' not in (output/(name+'.log')).read_text()
                record['result']='pass'
            finally:
                (directory/'result.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n')
                gui.terminate()
                try:gui.wait(timeout=5)
                except subprocess.TimeoutExpired:gui.kill();gui.wait(timeout=5)
                assert not Path('/proc',str(gui.pid)).exists()
            records.append(record)
        result={'result':'pass','cases':records,'software_only':True,'real_desktop_tested':False,
                'memory_optimization':False,'product_font_changed':False,'chinese_input_tested':False,
                'forced_x11_resize':True,'window_manager_minimum_size_enforcement_tested':False,
                'config_unchanged':True,'viewer_tested':False}
        (output/'home-layout-result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps(result),flush=True)
    finally:screen.close()
