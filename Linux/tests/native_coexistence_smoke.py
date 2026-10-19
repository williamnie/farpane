"""Two ordinary-user endpoints: simultaneous actual inbound/outbound sessions.

Container root only orchestrates separate UIDs and private X servers. Actual
GUI/Host/Viewer run unprivileged, without internal GUI smoke controls.
"""
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import socket
import subprocess
import sys
import time
import traceback

from native_host_smoke import RELEASE, stage_release
from native_lifecycle_smoke import Display, colored_pixels

assert os.geteuid() == 0 and Path('/.dockerenv').is_file()
assert socket.if_nameindex() == [(1, 'lo')]
output = Path(sys.argv[1]);output.mkdir(parents=True)
owner_uid, owner_gid = map(int,sys.argv[2:4]);assert owner_uid != 0
os.chown(output,owner_uid,owner_gid)
stage_release()
core = RELEASE/'libexec/farpane-core'
(output/'test-binaries.json').write_text(json.dumps({str(p.relative_to(RELEASE)):
    hashlib.file_digest(p.open('rb'), 'sha256').hexdigest() for p in (RELEASE/'farpane', core)}, indent=2)+'\n')
accounts, agents, guis, screens, desktops, patterns, states = {}, {}, {}, {}, {}, {}, {}
processes, logs, checks, stages = [], [], [], []
gui_bus_fault = os.environ.get('FARPANE_COEXIST_MODE') == 'gui-bus'
gui_bus_process = None
gui_bus_ids = []
layout = json.loads(Path('/workspace/Linux/tests/native-lifecycle-layout.json').read_text())
for index, role in enumerate(('a', 'b')):
    uid = 2201 + index
    try:
        pwd.getpwuid(uid)
        raise AssertionError('Fixture UID already exists')
    except KeyError:
        pass
    home = Path('/run/farpane-native-test')/role
    name = 'farpane-coexist-'+role
    subprocess.run(['useradd','--uid',str(uid),'--user-group','--home-dir',str(home),
                    '--no-create-home','--shell','/usr/sbin/nologin',name],check=True)
    gid = pwd.getpwuid(uid).pw_gid
    home.mkdir(mode=0o700);os.chown(home,uid,gid)
    env = dict(os.environ, HOME=str(home), USER=name, LOGNAME=name, XDG_RUNTIME_DIR=str(home),
               DBUS_SESSION_BUS_ADDRESS='unix:path='+str(home/'bus'),
               RUSTDESK_FORCED_DISPLAY_SERVER='x11', RUST_LOG='info', RUST_BACKTRACE='1')
    for variable,leaf in (('XDG_CONFIG_HOME','config'),('XDG_DATA_HOME','data'),
                          ('XDG_CACHE_HOME','cache'),('XDG_STATE_HOME','state')):
        directory=home/leaf;directory.mkdir(mode=0o700);os.chown(directory,uid,gid);env[variable]=str(directory)
    accounts[role] = dict(uid=uid,gid=gid,env=env,host_display=f':{91+index*2}',
                          gui_display=f':{92+index*2}',port=21118+index)


def start(name, role, arguments, env=None):
    a=accounts[role];log=(output/(name+'.log')).open('w');logs.append(log)
    process=subprocess.Popen(arguments,env=env or a['env'],user=a['uid'],group=a['gid'],extra_groups=[],
                             stdout=log,stderr=subprocess.STDOUT)
    processes.append(process)
    return process


def cli(role, command):
    a=accounts[role]
    result=subprocess.run([str(core),'--config-cli'],input=json.dumps(command),env=a['env'],user=a['uid'],
                          group=a['gid'],extra_groups=[],text=True,capture_output=True,timeout=10)
    assert result.returncode==0,result.stderr
    return json.loads(result.stdout)


def info(role, pid):
    # Read proc state as the target UID; default container root lacks ptrace.
    a=accounts[role]
    code='''import json,sys
from pathlib import Path
p=Path('/proc')/sys.argv[1]
try:
 children=set()
 for t in (p/'task').iterdir():
  try:children.update(int(n) for n in (t/'children').read_text().split())
  except FileNotFoundError:pass
 print(json.dumps({'pid':int(sys.argv[1]),'exe':str((p/'exe').readlink()),'uid':p.stat().st_uid,
  'children':sorted(children),'start_ticks':int((p/'stat').read_text().rsplit(') ',1)[1].split()[19])}))
except (FileNotFoundError,ProcessLookupError):print('null')
'''
    result=subprocess.run(['python3','-B','-c',code,str(pid)],env=a['env'],user=a['uid'],group=a['gid'],
                          extra_groups=[],text=True,capture_output=True,timeout=3)
    assert result.returncode==0,result.stderr
    return json.loads(result.stdout)


def wait(predicate, message, timeout=18):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        assert all(p.poll() is None for p in agents.values()), 'Private Host exited'
        value=predicate()
        if value:return value
        time.sleep(.1)
    for role, screen in screens.items():screen.capture(output/f'failure-{role}.png')
    raise AssertionError(message)


def listening(role):
    try:
        with socket.create_connection(('127.0.0.1',accounts[role]['port']),timeout=.1):return True
    except OSError:return False


def window(role):
    tree=subprocess.check_output(['xwininfo','-display',accounts[role]['gui_display'],'-root','-tree'],text=True)
    match=re.search(r'(0x[0-9a-f]+) "FarPane"',tree)
    return int(match[1],16) if match else None


def gui(role, label):
    a=accounts[role]
    env=dict(a['env'],DISPLAY=a['gui_display'],GSK_RENDERER='cairo',GTK_A11Y='none',GTK_IM_MODULE='gtk-im-context-simple')
    if gui_bus_fault and role == 'a':
        env['DBUS_SESSION_BUS_ADDRESS'] = 'unix:path=' + str(Path(a['env']['XDG_RUNTIME_DIR']) / 'gui-bus')
    assert not any(k.startswith('FARPANE_') and ('SMOKE_DIR' in k or 'SMOKE_EXIT' in k or 'SMOKE_REPORT' in k) for k in env)
    p=start(label,role,[str(RELEASE/'farpane')],env);guis[role]=p
    w=wait(lambda:window(role),'Missing GUI '+role);time.sleep(1)
    screens[role].focus(w)
    return p


def start_gui_bus(label):
    a = accounts['a']
    path = Path(a['env']['XDG_RUNTIME_DIR']) / 'gui-bus'
    path.unlink(missing_ok=True)
    address = 'unix:path=' + str(path)
    process = start(label, 'a', ['dbus-daemon', '--session', '--nofork', '--address=' + address])
    wait(path.is_socket, 'Private GUI-only bus did not start')
    identity = subprocess.check_output(['gdbus', 'call', '--address', address,
        '--dest', 'org.freedesktop.DBus', '--object-path', '/org/freedesktop/DBus',
        '--method', 'org.freedesktop.DBus.GetId'], env=a['env'], user=a['uid'], group=a['gid'],
        extra_groups=[], text=True, timeout=3).strip()
    gui_bus_ids.append(identity)
    return process


def connect(role, peer, label):
    screen=screens[role]
    log=Path(accounts[role]['env']['XDG_STATE_HOME'])/'farpane/native/viewer.log'
    before=log.read_text() if log.exists() else ''
    screen.click(layout['peer']);screen.type('127.0.0.1:'+str(accounts[peer]['port']));screen.click(layout['connect'])
    wait(lambda: log.exists() and log.read_text()!=before and 'PasswordRequired' in log.read_text(), 'Missing password '+role)
    screen.click(layout['password']);screen.type('native-coexist-'+peer);screen.click(layout['authenticate'])
    wait(lambda:any(c['authorized'] for c in cli(peer,{'type':'snapshot'})['inbound']), 'No authorized inbound '+peer)
    children=wait(lambda:info(role,guis[role].pid)['children'], 'No Viewer '+role)
    assert len(children)==1
    worker=info(role,children[0]);assert worker['exe']==str(core) and worker['uid']==accounts[role]['uid']
    stages.append({'stage':label,'viewer_role':role,'worker':worker})
    return worker


def color(role, value):
    d=desktops[role];d.x.XSetWindowBackground(d.display,patterns[role],value)
    d.x.XClearWindow(d.display,patterns[role]);d.x.XSync(d.display,0)


def visible(role, value, label):
    pixels=wait(lambda:(n if (n:=colored_pixels(screens[role].capture(),value))>70000 else None),
                'No fresh remote pixels '+label)
    screens[role].capture(output/(label+'.png'))
    return pixels


def fresh_both(label, colors):
    color('a',colors[0]);color('b',colors[1])
    result={'stage':label,'pixels_a':visible('a',colors[1],label+'-a'),
            'pixels_b':visible('b',colors[0],label+'-b')}
    for role in ('a','b'):
        state=cli(role,{'type':'snapshot'})
        assert len(state['inbound'])==1 and state['inbound'][0]['authorized']
        result[role]={'host_pid':agents[role].pid,'host_enabled':state['host_enabled'],
                      'inbound_id':state['inbound'][0]['id'],'gui':info(role,guis[role].pid)}
    stages.append(result)
    (output/'stages.json').write_text(json.dumps(stages,indent=2)+'\n')


try:
    x11=Path('/tmp/.X11-unix');x11.mkdir(exist_ok=True);x11.chmod(0o1777)
    for role,a in accounts.items():
        start(role+'-bus',role,['dbus-daemon','--session','--nofork','--address='+a['env']['DBUS_SESSION_BUS_ADDRESS']])
        wait(lambda:Path(a['env']['XDG_RUNTIME_DIR'],'bus').is_socket(),'Missing private bus')
        for kind,size in (('host','640x480x24'),('gui','1020x720x24')):
            display=a[kind+'_display']
            start(role+'-'+kind+'-xvfb',role,['Xvfb',display,'-screen','0',size,'-nolisten','tcp','-ac'])
            wait(lambda:Path('/tmp/.X11-unix/X'+display[1:]).exists(),'Missing private X server')
        desktops[role]=Display(a['host_display']);screens[role]=Display(a['gui_display'])
        d=desktops[role];patterns[role]=d.x.XCreateSimpleWindow(d.display,d.root,60,100,480,260,0,0,0x205090)
        d.x.XMapRaised(d.display,patterns[role]);d.x.XSync(d.display,0)
        state=cli(role,{'type':'snapshot'})
        state=cli(role,{'type':'set_authentication','data':{'mode':'permanent','password':'native-coexist-'+role,'revision':state['revision']}})
        state=cli(role,{'type':'set_host','data':{'enabled':True,'revision':state['revision']}})
        settings=next(Path(a['env']['XDG_CONFIG_HOME']).rglob('FarPane2.toml'))
        text=settings.read_text();assert '[options]\n' in text and 'direct-server' not in text
        settings.write_text(text.replace('[options]\n',f'[options]\ndirect-server = "Y"\ndirect-access-port = "{a["port"]}"\n',1))
        agents[role]=start(role+'-host',role,[str(core),'--server'],dict(a['env'],DISPLAY=a['host_display']))
        wait(lambda:listening(role),'Missing direct listener '+role)
        states[role]=cli(role,{'type':'snapshot'})
    assert states['a']['local_id']!=states['b']['local_id']
    if gui_bus_fault:
        gui_bus_process = start_gui_bus('a-private-gui-bus-1')
    for role in ('a','b'):gui(role,role+'-gui')
    worker_a=connect('a','b','connect-a-to-b')
    worker_b=connect('b','a','connect-b-to-a')
    fresh_both('simultaneous',(0x21906a,0x8030a0));checks.append('two-endpoints-each-inbound-and-outbound-present-new-frames')

    for role in ('a','b'):
        state=cli(role,{'type':'snapshot'})
        cli(role,{'type':'set_host','data':{'enabled':False,'revision':state['revision']}})
        wait(lambda:not listening(role),'Host-off did not stop new listener '+role)
    fresh_both('both-hosts-disabled',(0xb04030,0x3050b0))
    assert info('a',worker_a['pid'])==worker_a and info('b',worker_b['pid'])==worker_b
    checks+=['host-disable-stops-new-direct-connections','host-disable-preserves-existing-inbound-and-outbound-workers']
    for role in ('a','b'):
        state=cli(role,{'type':'snapshot'})
        cli(role,{'type':'set_host','data':{'enabled':True,'revision':state['revision']}})
        wait(lambda:listening(role),'Host-on did not restore listener '+role)
    fresh_both('both-hosts-reenabled',(0x805020,0x207080));checks.append('host-reenable-preserves-both-streams')

    # Connection authorization is a GUI role operation, not a config-cli
    # capability. Use the real connection manager's disconnect button.
    screens['a'].click((800,28));time.sleep(.7)
    screens['a'].capture(output/'connection-dialog.png')
    positions=Path('/workspace/Linux/tests/native-coexistence-layout.json')
    if os.environ.get('FARPANE_COEXIST_MODE')=='calibrate':
        positions=output/'layout.json'
        wait(positions.exists,'Private dialog calibration was not supplied',60)
    positions=json.loads(positions.read_text())
    (output/'used-layout.json').write_text(json.dumps(positions,indent=2)+'\n')
    screens['a'].click(positions['disconnect_inbound'])
    wait(lambda:not cli('a',{'type':'snapshot'})['inbound'],'Inbound did not disconnect')
    wait(lambda:info('b',worker_b['pid']) is None,'Disconnected peer Viewer not reaped')
    screens['a'].capture(output/'connection-disconnected.png')
    screens['a'].key(0xff1b,True);screens['a'].key(0xff1b,False);time.sleep(.3)
    screens['a'].focus(window('a'))
    color('b',0x408050);visible('a',0x408050,'inbound-disconnect-outbound-alive')
    assert info('a',worker_a['pid'])==worker_a
    checks.append('disconnect-inbound-does-not-kill-local-outbound')
    screens['b'].click(layout['disconnect']);time.sleep(.5)
    worker_b2=connect('b','a','reconnect-b-to-a');assert worker_b2['pid']!=worker_b['pid']
    fresh_both('peer-reconnected',(0x904060,0x407040));checks.append('peer-reconnect-restores-coexistence')

    gui_exit_on_bus_loss = None
    if gui_bus_fault:
        # Only the GUI/its disposable Viewer inherit this bus. Host and the
        # reverse direction use independent still-live buses and processes.
        inbound_before = cli('a', {'type': 'snapshot'})['inbound'][0]['id']
        lost_at = time.monotonic()
        gui_bus_process.terminate()
        assert gui_bus_process.wait(timeout=5) == 0
        gui_exit_on_bus_loss = guis['a'].wait(timeout=10)
        stages.append({'stage': 'gui-private-bus-lost', 'gui_pid': guis['a'].pid,
                       'gui_returncode': gui_exit_on_bus_loss, 'inbound_id': inbound_before,
                       'seconds_to_gui_exit': time.monotonic() - lost_at})
        checks.append('gui-own-bus-loss-exits-within-bound')
    else:
        screens['a'].click(layout['close']);assert guis['a'].wait(timeout=10)==0
    wait(lambda:info('a',worker_a['pid']) is None,'Closed GUI retained outgoing worker')
    if gui_bus_fault:
        # An exited orphan's /proc/exe also disappears while it is still a
        # zombie. The container init must actually reap it before we pass.
        wait(lambda:not Path(f'/proc/{worker_a["pid"]}').exists(), 'Orphaned Viewer was not reaped')
        checks.append('orphaned-viewer-absent-from-proc-after-gui-exit')
    wait(lambda:not cli('b',{'type':'snapshot'})['inbound'],'Remote retained closed outgoing session')
    color('a',0x3060a0);visible('b',0x3060a0,'gui-a-closed-inbound-alive')
    assert info('b',worker_b2['pid'])==worker_b2
    assert len(cli('a',{'type':'snapshot'})['inbound'])==1
    if gui_bus_fault:
        assert cli('a', {'type': 'snapshot'})['inbound'][0]['id'] == inbound_before
        checks.append('gui-bus-loss-reaps-outbound-and-preserves-same-inbound-with-fresh-pixels')
        gui_bus_process = start_gui_bus('a-private-gui-bus-2')
        assert len(set(gui_bus_ids)) == 2
        checks.append('replacement-gui-bus-has-new-identity')
    else:
        checks.append('gui-close-reaps-own-outbound-but-retains-host-and-inbound-stream')
    old_gui=guis['a'].pid;gui('a','a-gui-reopened');assert guis['a'].pid!=old_gui
    assert not info('a',guis['a'].pid)['children']
    screens['a'].capture(output/'reopened-home.png')
    color('a',0xa06030);visible('b',0xa06030,'gui-a-reopened-inbound-alive')
    checks.append('reopened-home-attaches-same-host-with-live-inbound')
    screens['a'].click(layout['close']);assert guis['a'].wait(timeout=10)==0
    screens['b'].click(layout['disconnect'])
    wait(lambda:info('b',worker_b2['pid']) is None,'Final worker not reaped')
    wait(lambda:not cli('a',{'type':'snapshot'})['inbound'],'Final inbound retained')
    screens['b'].click(layout['close']);assert guis['b'].wait(timeout=10)==0
    for role,state in states.items():
        after=cli(role,{'type':'snapshot'})
        assert agents[role].poll() is None and not after['inbound'] and after['host_enabled']
        assert after['local_id']==state['local_id'] and after['authentication']==state['authentication'] and after['server']==state['server']
    checks.append('both-guis-exit-workers-reaped-hosts-and-identities-preserved')
    result=dict(result='pass',checks=checks,host_pids={r:p.pid for r,p in agents.items()},
                private_uids={r:a['uid'] for r,a in accounts.items()},gpu=False,
                gui_bus_fault=gui_bus_fault, gui_exit_on_bus_loss=gui_exit_on_bus_loss,
                gui_bus_ids=gui_bus_ids,
                host_switch_control='authenticated config-cli',inbound_disconnect='actual GUI button',gui_controls='external XTest',
                system_service_tested=False,real_desktop_tested=False)
    (output/'coexistence-result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result),flush=True)
except Exception:
    (output/'failure.txt').write_text(traceback.format_exc())
    for role,screen in screens.items():screen.capture(output/f'failure-{role}.png')
    raise
finally:
    (output/'stages.json').write_text(json.dumps(stages,indent=2)+'\n')
    for role,a in accounts.items():
        source=Path(a['env']['XDG_STATE_HOME'])/'farpane/native/viewer.log'
        if source.exists():shutil.copyfile(source,output/(role+'-viewer-events.log'))
    # Close driver connections while the owned X servers are still alive;
    # Xlib's fatal I/O handler would otherwise mask the original exception.
    for d in list(screens.values())+list(desktops.values()):d.close()
    for p in reversed(processes):
        if p.poll() is None:
            p.terminate()
            try:p.wait(timeout=3)
            except subprocess.TimeoutExpired:p.kill();p.wait(timeout=3)
    for log in logs:log.close()
    for path in output.rglob('*'):
        assert not path.is_symlink()
        os.chown(path,owner_uid,owner_gid)
