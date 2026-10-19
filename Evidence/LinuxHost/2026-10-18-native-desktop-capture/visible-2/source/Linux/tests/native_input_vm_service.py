"""Unmodified native service/Host in the private kernel; controlled logind only."""
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import socket
import struct
import subprocess
import time

TEST = Path('/opt/farpane-input-test')
OUTPUT = Path('/run/farpane-input-results')


def exercise():
    assert os.getpid() == 1 and os.geteuid() == 0
    assert 'farpane.input-vm=1' in Path('/proc/cmdline').read_text().split()
    marker = json.loads(Path('/.farpane-input-vm').read_text())
    assert marker['isolation'] == 'guest-kernel-uinput'
    core = Path('/opt/farpane/current/libexec/farpane-core').resolve(strict=True)
    account = pwd.getpwuid(1000)
    runtime = Path('/run/user/1000')
    runtime.mkdir(parents=True, mode=0o700)
    os.chown(runtime, 1000, account.pw_gid)
    OUTPUT.mkdir()
    os.chown(OUTPUT, 1000, account.pw_gid)
    session_dir = Path('/run/farpane-service-test')
    session_dir.mkdir()
    session_file = session_dir / 'session.json'
    session_file.write_text('{}')
    env = dict(PATH='/usr/bin:/bin', HOME=account.pw_dir, USER=account.pw_name,
               LANG='C.UTF-8', XDG_RUNTIME_DIR=str(runtime), XDG_SESSION_ID='vm-input',
               XDG_SESSION_TYPE='wayland', XDG_SESSION_CLASS='user',
               XDG_CURRENT_DESKTOP='GNOME', LIBGL_ALWAYS_SOFTWARE='1',
               GALLIUM_DRIVER='llvmpipe', GTK_A11Y='none', NO_AT_BRIDGE='1',
               GSETTINGS_BACKEND='keyfile',
               DBUS_SESSION_BUS_ADDRESS='unix:path='+str(runtime/'bus'),
               RUST_LOG='debug')
    for key, name in [('XDG_CONFIG_HOME','config'), ('XDG_DATA_HOME','data'),
                      ('XDG_CACHE_HOME','cache'), ('XDG_STATE_HOME','state')]:
        path = runtime / name
        path.mkdir(mode=0o700)
        os.chown(path, 1000, account.pw_gid)
        env[key] = str(path)
    children = []
    logs = []
    report = {'scope':'private-root-host-startup', 'session_provider':'controlled-loginctl',
              'core_sha256':None, 'input_text_sent':False, 'host_input_exposed':False}

    def launch(name, args, environment=env, user=True):
        log = (OUTPUT/(name+'.log')).open('w')
        logs.append(log)
        command = (['setpriv','--reuid=1000','--regid='+str(account.pw_gid),
                    '--clear-groups'] if user else []) + [str(a) for a in args]
        process = subprocess.Popen(command, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT)
        children.append(process)
        return process

    def wait(predicate, message, seconds=12):
        deadline = time.monotonic()+seconds
        while time.monotonic()<deadline:
            value = predicate()
            if value:
                return value
            time.sleep(.1)
        raise TimeoutError(message)

    def cli(command):
        run = subprocess.run(['setpriv','--reuid=1000','--regid='+str(account.pw_gid),
                              '--clear-groups',str(core),'--config-cli'],
                             input=json.dumps(command), env=env, capture_output=True,
                             text=True, timeout=10)
        assert run.returncode == 0, run.stderr
        return json.loads(run.stdout)

    try:
        import hashlib
        with core.open('rb') as stream:
            report['core_sha256'] = hashlib.file_digest(stream,'sha256').hexdigest()
        # No emulated NIC: bring up only the private kernel's loopback device.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as net:
            request = struct.pack('16sH22x', b'lo', 0)
            flags = struct.unpack('16sH22x', fcntl.ioctl(net, 0x8913, request))[1]
            fcntl.ioctl(net, 0x8914, struct.pack('16sH22x', b'lo', flags|1))
        subprocess.run(['dbus-uuidgen','--ensure'], check=True, timeout=3)
        Path('/run/dbus').mkdir()
        launch('system-bus',['dbus-daemon','--system','--nofork'],user=False)
        wait(lambda:Path('/run/dbus/system_bus_socket').is_socket(),'Private system bus did not start')
        launch('udev',['/usr/lib/systemd/systemd-udevd'],user=False)
        subprocess.run(['udevadm','trigger','--action=add'],check=True,timeout=5)
        launch('user-bus',['dbus-daemon','--session','--nofork',
                           '--address='+env['DBUS_SESSION_BUS_ADDRESS']])
        wait(lambda:(runtime/'bus').is_socket(),'Private user bus did not start')
        mutter = launch('mutter',['mutter','--headless','--wayland','--virtual-monitor=640x480'])
        def display_ready():
            assert mutter.poll() is None, 'Private Mutter exited'
            values = [p for p in runtime.glob('wayland-*') if p.is_socket()]
            return values[0] if len(values)==1 else None
        wayland = wait(display_ready,'Private Wayland socket did not start')
        def xwayland_ready():
            match = re.search(r'using (unix:/tmp/\.X11-unix/X[0-9]+) for managed services',
                              (OUTPUT/'mutter.log').read_text())
            authority = list(runtime.glob('.mutter-Xwaylandauth.*'))
            return (match[1],str(authority[0])) if match and len(authority)==1 else None
        display, authority = wait(xwayland_ready,'Private Xwayland authority not ready')
        env.update(WAYLAND_DISPLAY=wayland.name, DISPLAY=display, XAUTHORITY=authority,
                   GDK_BACKEND='wayland',GSK_RENDERER='cairo')
        # Force the lazy managed listener to start the real Xwayland process.
        subprocess.run(['setpriv','--reuid=1000','--regid='+str(account.pw_gid),
                        '--clear-groups','xdpyinfo'],env=env,check=True,
                       stdout=subprocess.DEVNULL,timeout=5)
        launch('pipewire',['pipewire'])
        launch('wireplumber',['wireplumber'])
        subprocess.run(['setpriv','--reuid=1000','--regid='+str(account.pw_gid),
                        '--clear-groups','dbus-update-activation-environment','--all'],
                       env=env,check=True,timeout=5)
        leader = launch('desktop-environment',['sleep','90'])
        target = launch('target',['python3',TEST/'native_gnome_input_smoke.py',
                                 '--target',OUTPUT])
        wait(lambda:(OUTPUT/'entry.json').is_file(),'Private GTK target did not start')
        state = cli({'type':'snapshot'})
        state = cli({'type':'set_authentication','data':{
            'mode':'permanent','password':'native-viewer-smoke','revision':state['revision']}})
        state = cli({'type':'set_host','data':{'enabled':True,'revision':state['revision']}})
        config = next((runtime/'config').rglob('FarPane2.toml'))
        text = config.read_text()
        assert '[options]\n' in text and 'direct-server' not in text
        config.write_text(text.replace('[options]\n','[options]\ndirect-server = "Y"\n',1))
        session_file.write_text(json.dumps({'sid':'vm-input','uid':1000,
            'name':account.pw_name,'leader':leader.pid,'display':display,'type':'wayland'}))
        root_env = dict(PATH='/usr/bin:/bin',HOME='/root',LANG='C.UTF-8',RUST_LOG='debug')
        service = launch('root-service',[core,'--service'],root_env,user=False)
        wait(lambda:(runtime/'farpane/agent.sock').is_socket(),'Root did not start desktop Host')
        def agent_ready():
            value = cli({'type':'snapshot'})
            return value if value['role']=='agent' else None
        snapshot = wait(agent_ready,'Desktop Host did not own control')
        def keyboard_ready():
            matches = [p for p in Path('/sys/class/input').glob('event*')
                       if (p/'device/name').read_text().strip()=='RustDesk UInput Keyboard']
            return matches[0] if len(matches)==1 else None
        keyboard = wait(keyboard_ready,'Product root service did not create its uinput keyboard')
        role_list = []
        for path in Path('/proc').iterdir():
            if not path.name.isdecimal():
                continue
            try:
                if (path/'exe').resolve()!=core:
                    continue
                argv = (path/'cmdline').read_bytes().split(b'\0')
                role_list.append({'pid':int(path.name),'uid':path.stat().st_uid,
                                  'role':argv[1].decode()})
            except (FileNotFoundError,ProcessLookupError):
                pass
        assert any(p['role']=='--service' and p['uid']==0 for p in role_list)
        assert any(p['role']=='--server' and p['uid']==1000 for p in role_list)
        assert service.poll() is None and target.poll() is None
        report.update(result='pass', roles=role_list, product_keyboard=keyboard.name,
                      desktop=snapshot['desktop'], host_enabled=snapshot['host_enabled'])
        input_fds = set()
        for path in Path('/proc',str(mutter.pid),'fd').iterdir():
            try:target_name = str(path.readlink())
            except FileNotFoundError:continue
            if target_name.startswith('/dev/input/'):
                input_fds.add(target_name)
        report['mutter_input_fds'] = sorted(input_fds)
        if marker['stage']=='service':
            return report
        viewer_output = OUTPUT/'viewer'
        viewer_output.mkdir()
        os.chown(viewer_output,1000,account.pw_gid)
        gui_env = dict(env, DISPLAY=':92',GDK_BACKEND='x11',XDG_SESSION_TYPE='x11',
                       FARPANE_VIEWER_SMOKE_DIR=str(viewer_output),
                       FARPANE_NATIVE_TEST_MODE='input',GTK_IM_MODULE='gtk-im-context-simple')
        for key in ('XAUTHORITY','WAYLAND_DISPLAY','XDG_SESSION_ID'):
            gui_env.pop(key,None)
        launch('viewer-display',['Xvfb',':92','-screen','0','1020x720x24','-nolisten','tcp'],gui_env)
        wait(lambda:Path('/tmp/.X11-unix/X92').is_socket(),'Viewer Xvfb did not start')
        gui = launch('viewer',[core.parent.parent/'farpane'],gui_env)
        def viewer_ready():
            path=viewer_output/'viewer-progress.json'
            if path.exists():
                try:value=json.loads(path.read_text())
                except json.JSONDecodeError:return None
                if marker['stage']=='viewer-notice':
                    phases=[e['event']['data'] for e in value['events'] if e['event']['type']=='phase']
                    if any(p['phase']=='failed' for p in phases):
                        raise RuntimeError('Screen-selection notice was mapped to a connection failure')
                    if phases and phases[-1]['phase']=='authenticating' and '选择要共享的屏幕' in phases[-1]['detail']:
                        assert not value['presented'] and not value['worker_reaped']
                        return value
                if value.get('presented'):
                    return value
                if value.get('phase') in ('failed','closed'):
                    raise RuntimeError('Private Viewer ended before a frame: '+str(value))
            assert gui.poll() is None,'Private Viewer exited'
            return None
        progress=wait(viewer_ready,'Private Viewer did not receive a frame',seconds=25)
        report.update(scope='private-root-host-viewer-'+marker['stage'],
                      viewer_presented=progress['presented'],
                      selection_notice_nonterminal=marker['stage']=='viewer-notice')
        return report
    finally:
        for process in reversed(children):
            if process.poll() is None:
                process.terminate()
                try:process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill();process.wait(timeout=3)
        for log in logs:
            log.close()
        # Only this VM's synthetic logs; no credentials or user state were copied.
        for path in sorted(OUTPUT.glob('*.log')):
            print('VM_LOG '+path.name+' '+json.dumps(path.read_text(errors='replace')[-16000:]),flush=True)
        for path in sorted((OUTPUT/'viewer').glob('*progress.json')):
            print('VM_GUI_REPORT '+path.name+' '+path.read_text(),flush=True)
        for home in (Path('/root'), Path(account.pw_dir)):
            for path in sorted((home/'.local/share/logs/FarPane').glob('**/*.log')):
                print('VM_CORE_LOG '+str(path)+' '+json.dumps(path.read_text(errors='replace')[-24000:]),flush=True)
