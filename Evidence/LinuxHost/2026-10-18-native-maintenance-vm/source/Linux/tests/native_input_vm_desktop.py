"""Real GNOME/logind on guest-only VKMS; never execute on a workstation."""
import ctypes
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import time
import termios
import traceback

TEST = Path('/opt/farpane-input-test')
OUTPUT = Path('/run/farpane-input-results')


def require_guest():
    assert 'farpane.input-vm=1' in Path('/proc/cmdline').read_text().split()
    marker = json.loads(Path('/.farpane-input-vm').read_text())
    assert marker['isolation']=='guest-kernel-uinput' and marker['stage']=='desktop'
    # The desktop UID cannot read the root PID 1 executable link. The boot
    # marker/cmdline/boot-ID binding is checked independently of this label.
    assert Path('/proc/1/comm').read_text().strip()=='systemd'
    probe = json.loads(Path('/run/farpane-kernel-probe.json').read_text())
    assert probe['boot_id']==Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    return probe


def wait(predicate, message, seconds=15):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        value=predicate()
        if value:return value
        time.sleep(.1)
    raise TimeoutError(message)


def session():
    require_guest()
    assert os.geteuid()==1000
    maintenance=json.loads(Path('/.farpane-input-vm').read_text()).get('scenario')=='maintenance'
    assert os.environ['XDG_SESSION_ID']
    runtime=Path('/run/user/1000')
    assert runtime.stat().st_uid==1000
    env=dict(os.environ,LANG='C.UTF-8',XDG_CURRENT_DESKTOP='GNOME',
             XDG_RUNTIME_DIR=str(runtime),LIBGL_ALWAYS_SOFTWARE='1',
             GALLIUM_DRIVER='llvmpipe',GTK_A11Y='none',NO_AT_BRIDGE='1',
             GSETTINGS_BACKEND='keyfile')
    env['FARPANE_GNOME_INPUT_TARGET']=json.loads(Path('/.farpane-input-vm').read_text())['target']
    for key,name in [('XDG_CONFIG_HOME','config'),('XDG_DATA_HOME','data'),
                     ('XDG_CACHE_HOME','cache'),('XDG_STATE_HOME','state')]:
        defaults={'config':'.config','data':'.local/share','cache':'.cache','state':'.local/state'}
        path=Path.home()/defaults[name] if maintenance else runtime/name
        path.mkdir(parents=True,exist_ok=True,mode=0o700);env[key]=str(path)
    children=[];logs=[]
    def launch(name,args):
        log=(OUTPUT/(name+'.log')).open('w');logs.append(log)
        p=subprocess.Popen(list(map(str,args)),env=env,stdin=subprocess.DEVNULL,
                           stdout=log,stderr=subprocess.STDOUT)
        children.append(p);return p
    try:
        probe=subprocess.run(['bwrap','--unshare-all','--ro-bind','/','/','/bin/true'],
                             env=env,text=True,capture_output=True,timeout=5)
        (OUTPUT/'sandbox-probe.log').write_text(json.dumps({'returncode':probe.returncode,
            'stdout':probe.stdout,'stderr':probe.stderr,
            'capabilities':[line for line in Path('/proc/self/status').read_text().splitlines()
                            if line.startswith(('Cap','NoNewPrivs:','Uid:','Gid:'))],
            'userns_max':Path('/proc/sys/user/max_user_namespaces').read_text(),
            'apparmor_userns':Path('/proc/sys/kernel/apparmor_restrict_unprivileged_userns').read_text()}))
        launch('pipewire',['pipewire']);launch('wireplumber',['wireplumber'])
        for schema,key,value in [('org.gnome.desktop.session','idle-delay','0'),
                                 ('org.gnome.desktop.screensaver','lock-enabled','false'),
                                 ('org.gnome.shell','welcome-dialog-last-shown-version','50.1')]:
            subprocess.run(['gsettings','set',schema,key,value],env=env,check=True,timeout=5)
        shell=launch('gnome',['gnome-shell','--wayland','--display-server'])
        def display_ready():
            assert shell.poll() is None,'Native GNOME exited'
            displays=[p for p in runtime.glob('wayland-*') if p.is_socket()]
            log=(OUTPUT/'gnome.log').read_text()
            match=re.search(r'using (unix:/tmp/\.X11-unix/X[0-9]+) for managed services',log)
            auth=list(runtime.glob('.mutter-Xwaylandauth.*'))
            return (displays[0],match[1],auth[0]) if len(displays)==1 and match and len(auth)==1 else None
        wayland,display,auth=wait(display_ready,'Native GNOME did not become ready',40)
        env.update(WAYLAND_DISPLAY=wayland.name,DISPLAY=display,XAUTHORITY=str(auth),
                   GDK_BACKEND='wayland',GSK_RENDERER='cairo')
        subprocess.run(['dbus-update-activation-environment','--all'],env=env,check=True,timeout=5)
        target=None
        if not maintenance:
            target=launch('target',['python3',TEST/'native_gnome_input_smoke.py','--target',OUTPUT])
            wait(lambda:(OUTPUT/'entry.json').exists(),'Native Wayland target did not start')
        keys=['PATH','HOME','USER','LANG','XDG_RUNTIME_DIR','XDG_SESSION_ID','XDG_SESSION_TYPE',
              'XDG_SESSION_CLASS','XDG_CURRENT_DESKTOP','XDG_CONFIG_HOME','XDG_DATA_HOME',
              'XDG_CACHE_HOME','XDG_STATE_HOME','DISPLAY','XAUTHORITY','WAYLAND_DISPLAY',
              'DBUS_SESSION_BUS_ADDRESS','GDK_BACKEND','GSK_RENDERER','GTK_A11Y']
        ready={'gnome_pid':shell.pid,'target_pid':target.pid if target else None,
               'environment':{k:env[k] for k in keys if k in env}}
        (OUTPUT/'desktop-ready.json').write_text(json.dumps(ready))
        deadline=time.monotonic()+(240 if maintenance else 100)
        while time.monotonic()<deadline:
            assert shell.poll() is None and (target is None or target.poll() is None)
            time.sleep(.2)
    finally:
        for child in reversed(children):
            if child.poll() is None:child.terminate()
        for child in children:
            try:child.wait(timeout=3)
            except subprocess.TimeoutExpired:child.kill();child.wait(timeout=3)
        for log in logs:log.close()


def properties(*args):
    text=subprocess.check_output(['loginctl',*args,'--no-pager'],text=True,timeout=3)
    return dict(line.split('=',1) for line in text.splitlines() if '=' in line)


def controller():
    result=require_guest()
    assert os.geteuid()==0
    result.update(result='fail',scope='private-native-gnome-root-input-startup')
    OUTPUT.mkdir(mode=0o755)
    account=pwd.getpwuid(1000);os.chown(OUTPUT,1000,account.pw_gid)
    core=Path('/opt/farpane/current/libexec/farpane-core').resolve(strict=True)
    service=None;service_log=None
    try:
        assert Path('/usr/bin/loginctl').read_bytes().startswith(b'\x7fELF')
        subprocess.run(['modprobe','vkms'],check=True,timeout=5)
        subprocess.run(['udevadm','settle','--timeout=5'],check=True,timeout=6)
        cards=[p for p in Path('/sys/class/drm').glob('card[0-9]')]
        result['guest_drm']=[{'card':p.name,'device':str((p/'device').resolve()),
                              'driver':str((p/'device/driver').resolve())} for p in cards]
        # Linux 7 uses the faux bus for VKMS; its driver has no module symlink.
        assert len(cards)==1 and (cards[0]/'device').resolve().name=='vkms',result['guest_drm']
        properties_text=subprocess.check_output(['udevadm','info','--query=property','--path='+str(cards[0])],text=True,timeout=3)
        result['guest_drm_properties']={k:v for k,v in (line.split('=',1) for line in properties_text.splitlines() if '=' in line)
                                        if k in ('DEVPATH','TAGS','CURRENT_TAGS','ID_SEAT')}
        subprocess.run(['systemctl','stop','getty@tty1.service'],check=True,timeout=8)
        subprocess.run(['systemctl','start','--no-block','farpane-input-session.service'],check=True,timeout=5)
        print('VM_STAGE=starting-real-gnome-login',flush=True)
        def desktop_ready():
            state=subprocess.check_output(['systemctl','show','--property=ActiveState',
                                           '--value','farpane-input-session.service'],text=True,timeout=2).strip()
            assert state!='failed','Private graphical session failed; see guest logs'
            return (OUTPUT/'desktop-ready.json').exists()
        wait(desktop_ready,'Native graphical login did not start',55)
        print('VM_STAGE=graphical-login-ready',flush=True)
        ready=json.loads((OUTPUT/'desktop-ready.json').read_text());env=ready['environment']
        sid=env['XDG_SESSION_ID']
        login=properties('show-session',sid)
        assert login['Type']=='wayland' and login['Class']=='user' and login['User']=='1000',login
        assert login['Active']=='yes' and login['Seat']=='seat0',login
        assert properties('show-seat','seat0')['ActiveSession']==sid
        result['logind']={k:login[k] for k in ['Id','User','Active','Type','Class','Seat','Leader']}
        def cli(command):
            run=subprocess.run(['setpriv','--reuid=1000','--regid='+str(account.pw_gid),
                                '--clear-groups',str(core),'--config-cli'],env=env,
                               input=json.dumps(command),text=True,capture_output=True,timeout=10)
            assert run.returncode==0,run.stderr
            return json.loads(run.stdout)
        state=cli({'type':'snapshot'})
        state=cli({'type':'set_authentication','data':{
            'mode':'permanent','password':'native-viewer-smoke','revision':state['revision']}})
        state=cli({'type':'set_host','data':{'enabled':True,'revision':state['revision']}})
        config=next(Path(env['XDG_CONFIG_HOME']).rglob('FarPane2.toml'))
        text=config.read_text();assert '[options]\n' in text and 'direct-server' not in text
        config.write_text(text.replace('[options]\n','[options]\ndirect-server = "Y"\n',1))
        service_log=(OUTPUT/'root-service.log').open('w')
        service=subprocess.Popen([str(core),'--service'],
            env=dict(PATH='/usr/bin:/bin',HOME='/root',LANG='C.UTF-8',RUST_LOG='debug'),
            stdin=subprocess.DEVNULL,stdout=service_log,stderr=subprocess.STDOUT)
        wait(lambda:Path('/run/user/1000/farpane/agent.sock').is_socket(),'Native Host did not start')
        def keyboard_ready():
            matches=[p for p in Path('/sys/class/input').glob('event*')
                     if (p/'device/name').read_text().strip()=='RustDesk UInput Keyboard']
            return matches[0] if len(matches)==1 else None
        keyboard=wait(keyboard_ready,'Product uinput keyboard was not created')
        device='/dev/input/'+keyboard.name
        def consumer_ready():
            fds=[]
            for path in Path('/proc',str(ready['gnome_pid']),'fd').iterdir():
                try:name=str(path.readlink())
                except FileNotFoundError:continue
                if name==device:fds.append(int(path.name))
            return fds
        fds=wait(consumer_ready,'Native GNOME did not open the product keyboard',10)
        state=cli({'type':'snapshot'});assert state['role']=='agent' and state['host_enabled']
        result.update(result='pass',native_desktop={'renderer':'guest VKMS/software Mesa',
                      'gnome_pid':ready['gnome_pid'],'product_keyboard':device,'input_fds':fds,
                      'session_provider':'real-systemd-logind','host_enabled':True,
                      'input_text_sent':False,'host_input_exposed':False})
        if json.loads(Path('/.farpane-input-vm').read_text())['input_driver']=='wire':
            from native_input_vm_wire import exercise
        else:
            from native_input_vm_network import exercise
        result['network_input']=exercise(core,env,account,device)
        result['native_desktop']['input_text_sent']=True
        result.update(scope='private-native-gnome-network-input',full_farpane_input_tested=True)
    except Exception:
        result['result']='fail'
        result['failure']=traceback.format_exc()
    finally:
        if service is not None and service.poll() is None:
            service.terminate()
            try:service.wait(timeout=5)
            except subprocess.TimeoutExpired:service.kill();service.wait(timeout=3)
        if service_log:service_log.close()
        subprocess.run(['systemctl','stop','farpane-input-session.service'],check=False,timeout=8)
        for path in sorted(OUTPUT.glob('*.log')):
            print('VM_LOG '+path.name+' '+json.dumps(path.read_text(errors='replace')[-22000:]),flush=True)
        for path in [OUTPUT/'network-input.json',OUTPUT/'entry.json',
                     OUTPUT/'viewer/viewer-progress.json',OUTPUT/'viewer/viewer.json']:
            if path.exists():print('VM_TEST_REPORT '+path.name+' '+path.read_text(),flush=True)
        journal=subprocess.run(['journalctl','-b','--no-pager','-n','140'],capture_output=True,text=True,timeout=5)
        print('VM_SYSTEM_JOURNAL='+json.dumps(journal.stdout),flush=True)
        for home in [Path('/root'),Path(account.pw_dir)]:
            for path in sorted((home/'.local/share/logs/FarPane').glob('**/*.log')):
                print('VM_CORE_LOG '+str(path)+' '+json.dumps(path.read_text(errors='replace')[-18000:]),flush=True)
        print('FARPANE_INPUT_VM_RESULT='+json.dumps(result),flush=True)
        os.sync()
        termios.tcdrain(sys.stdout.fileno())
        # Orderly shutdown lets guest journald/ext4 finish their own writes.
        # Guard above verified this private boot before any process/device work.
        subprocess.run(['systemctl','--no-block','poweroff'],check=True,timeout=5)


if __name__=='__main__':
    if sys.argv[1:]==['--session']:session()
    else:
        assert not sys.argv[1:]
        controller()
