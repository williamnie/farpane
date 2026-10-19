"""Real package/systemd/user-entry maintenance, only in the marked private VM."""
import hashlib
import base64
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys
import termios
import time
import tomllib
import traceback

from native_input_vm_desktop import OUTPUT, TEST, properties, require_guest, wait


def require_maintenance():
    result = require_guest()
    marker = json.loads(Path('/.farpane-input-vm').read_text())
    assert marker.get('scenario') == 'maintenance' and os.geteuid() == 0
    assert len(marker['maintenance_packages']) == 2
    return result, marker


def processes(release):
    found = []
    root = Path('/opt/farpane/releases') / release
    for path in Path('/proc').iterdir():
        if not path.name.isdecimal():
            continue
        try:
            executable = path.joinpath('exe').readlink()
            if executable not in (root/'farpane', root/'libexec/farpane-core'):
                continue
            args = path.joinpath('cmdline').read_bytes().split(b'\0')
            role = 'gui' if executable.name == 'farpane' else args[1].decode()
            found.append({'pid':int(path.name), 'uid':path.stat().st_uid, 'role':role,
                          'start':path.joinpath('stat').read_text().rsplit(') ',1)[1].split()[19]})
        except (FileNotFoundError, ProcessLookupError):
            pass
    return sorted(found,key=lambda p:p['pid'])


def controller():
    result, marker = require_maintenance()  # Before dpkg, systemctl or any write.
    result.update(result='fail', scope='private-systemd-native-maintenance', checks=[], generations=[])
    OUTPUT.mkdir(mode=0o755)
    account = pwd.getpwuid(1000)
    os.chown(OUTPUT,1000,account.pw_gid)
    env = None
    def run(*args, user=False, ok=True, input=None):
        command = list(map(str,args))
        if user:
            assert env is not None
            command = ['setpriv','--reuid=1000','--regid='+str(account.pw_gid),'--clear-groups',*command]
        done = subprocess.run(command,env=env if user else None,input=input,
                              text=True,capture_output=True,timeout=45)
        with (OUTPUT/'maintenance.log').open('a') as log:
            log.write(json.dumps({'argv':list(map(str,args)), 'user':user, 'exit':done.returncode})+'\n')
            # Config helper responses may contain credentials; retain only assertions.
            if '--config-cli' not in command:log.write(done.stdout+done.stderr+'\n')
        if '--config-cli' not in command:print('VM_MAINTENANCE_STEP='+str(args[0])+' '+str(args[1] if len(args)>1 else '')+' exit='+str(done.returncode),flush=True)
        assert (done.returncode==0)==ok,(args,done.returncode,done.stderr)
        return done.stdout
    def cli(release, command):
        core=Path('/opt/farpane/releases')/release/'libexec/farpane-core'
        return json.loads(run(core,'--config-cli',user=True,input=json.dumps(command)))
    def snapshot(release):
        state=cli(release,{'type':'snapshot'})
        assert state['role']=='agent' and state['host_enabled'] and state['permanent_password_set']
        return {k:state[k] for k in ('local_id','authentication','server','gpu_enabled','devices','permanent_password_set')}
    def identity():
        files=list(Path(env['XDG_CONFIG_HOME']).rglob('FarPane.toml'))
        assert len(files)==1
        data=tomllib.loads(files[0].read_text())
        selected={k:data[k] for k in ('id','password','salt','key_pair','enc_id') if k in data}
        assert selected.get('password'), 'Missing synthetic permanent password storage'
        return hashlib.sha256(json.dumps(selected,sort_keys=True).encode()).hexdigest(), sorted(selected)
    def observe(release, gui=False):
        expected=['--server','--service']+(['gui'] if gui else [])
        def ready():
            found=processes(release)
            return found if sorted(p['role'] for p in found)==sorted(expected) else None
        found=wait(ready,'Expected service/Host/GUI generation did not become ready',20)
        assert len({p['pid'] for p in found})==len(expected)
        assert all(p['uid']==(0 if p['role']=='--service' else 1000) for p in found)
        service=properties('show-session',env['XDG_SESSION_ID'])
        assert service['Active']=='yes' and service['Type']=='wayland'
        main=int(run('systemctl','show','farpane.service','-p','MainPID','--value').strip())
        assert main==next(p['pid'] for p in found if p['role']=='--service')
        assert run('systemctl','is-enabled','farpane.service',ok=False).strip()=='disabled'
        result['generations'].append({'release':release,'processes':found})
        return found
    def launch_gui(release):
        data=Path(env['XDG_DATA_HOME'])
        desktop=data/'applications/org.farpane.FarPane.desktop'
        assert str(Path('/opt/farpane/releases')/release/'farpane') in desktop.read_text()
        for path in [data/'icons/hicolor/scalable/apps/org.farpane.FarPane.svg',
                     data/'icons/hicolor/1024x1024/apps/org.farpane.FarPane.png',
                     data/'dbus-1/services/org.farpane.FarPane.service']:
            assert path.is_file() and path.stat().st_uid==1000
        assert 'DBusActivatable=true' in desktop.read_text()
        # Await the actual activation reply before observing process ownership.
        # A short-lived launcher process/exec alone is not application readiness.
        run('gdbus','call','--session','--dest','org.farpane.FarPane',
            '--object-path','/org/farpane/FarPane','--method',
            'org.freedesktop.Application.Activate','{}',user=True)
        try:
            current=observe(release,gui=True)
        except Exception:
            result['gui_failure_processes']=processes(release)
            probe=subprocess.run(['setpriv','--reuid=1000','--regid='+str(account.pw_gid),'--clear-groups',
                'gdbus','call','--session','--dest','org.farpane.FarPane','--object-path','/org/farpane/FarPane',
                '--method','org.freedesktop.Application.Activate','{}'],env=env,text=True,capture_output=True,timeout=30)
            result['gui_activation_diagnostic']={'exit':probe.returncode,'stdout':probe.stdout,'stderr':probe.stderr}
            raise
        # Real session bus identity confirms an activated application, not just exec.
        reply=run('gdbus','call','--session','--dest','org.freedesktop.DBus',
                  '--object-path','/org/freedesktop/DBus','--method',
                  'org.freedesktop.DBus.GetConnectionUnixProcessID','org.farpane.FarPane',user=True)
        assert str(next(p['pid'] for p in current if p['role']=='gui')) in reply
        result.setdefault('gui_activation',[]).append({'release':release,'method':'org.freedesktop.Application.Activate',
            'bus_owner_pid':next(p['pid'] for p in current if p['role']=='gui')})
        return current
    try:
        assert not Path('/opt/farpane').exists()
        run('modprobe','vkms');run('udevadm','settle','--timeout=5')
        cards=list(Path('/sys/class/drm').glob('card[0-9]'))
        assert len(cards)==1 and (cards[0]/'device').resolve().name=='vkms'
        run('systemctl','stop','getty@tty1.service')
        run('systemctl','start','--no-block','farpane-input-session.service')
        wait(lambda:(OUTPUT/'desktop-ready.json').is_file(),'Private GNOME login not ready',55)
        ready=json.loads((OUTPUT/'desktop-ready.json').read_text());env=ready['environment']
        login=properties('show-session',env['XDG_SESSION_ID'])
        assert login['Active']=='yes' and login['User']=='1000' and login['Type']=='wayland' and login['Class']=='user'
        result['logind']={k:login[k] for k in ('Id','User','Active','Type','Class','Seat','Leader')}
        result['checks'].append('real_systemd_logind_gnome_session')

        unrelated=Path('/etc/systemd/system/farpane-unrelated-test.service')
        unrelated.write_text('[Service]\nExecStart=/bin/sleep infinity\n')
        run('systemctl','daemon-reload');run('systemctl','start',unrelated.name)
        unrelated_pid=run('systemctl','show',unrelated.name,'-p','MainPID','--value')
        for entry in marker['maintenance_packages']:
            package=TEST/'packages'/entry['file']
            assert hashlib.sha256(package.read_bytes()).hexdigest()==entry['sha256']
        run('dpkg','--install',TEST/'packages'/('1.deb' if marker.get('desktop_launch_probe') else '0.deb'))
        prefix=Path('/usr/lib/farpane-native-candidate')
        first=json.loads((prefix/'candidate.json').read_text())['artifact_id']
        run('farpane-maintenance','plan',first,'--expect-current','none')
        run('farpane-maintenance','activate',first,'--expect-current','none','--maintenance-window')
        run('farpane-user-integration','bind',first,'--previous','none',user=True)
        state=cli(first,{'type':'snapshot'})
        state=cli(first,{'type':'set_authentication','data':{'mode':'permanent','password':'private-maintenance-only','revision':state['revision']}})
        state=cli(first,{'type':'set_gpu','data':{'enabled':False,'retry':False,'revision':state['revision']}})
        cli(first,{'type':'set_host','data':{'enabled':True,'revision':state['revision']}})
        run('systemctl','start','farpane.service')
        observe(first)
        expected=snapshot(first);credential_hash,credential_fields=identity()
        if marker.get('desktop_launch_probe'):
            from native_desktop_launch_vm import exercise
            result['desktop_launch']=exercise(env,first,ready['gnome_pid'])
            result.update(result='pass',scope='private-gnome-desktop-launch',
                          real_remote_connection_tested=False,input_text_tested=False,gpu_tested=False)
            return
        original=launch_gui(first)
        result['checks'].append('real_deb_initial_activation_user_bind_and_gui_bus_owner')
        unknown=Path(env['XDG_CONFIG_HOME'])/'autostart/private-user.desktop'
        unknown.parent.mkdir(parents=True,exist_ok=True)
        unknown.write_text('[Desktop Entry]\nType=Application\nName=User sentinel\nExec=/bin/true\n')
        os.chown(unknown.parent,1000,account.pw_gid);os.chown(unknown,1000,account.pw_gid)
        unknown_before=unknown.read_bytes()

        run('dpkg','--install',TEST/'packages/1.deb')
        second=json.loads((prefix/'candidate.json').read_text())['artifact_id']
        assert second!=first and snapshot(first)==expected
        result['after_package_upgrade_processes']=processes(first)
        assert result['after_package_upgrade_processes']==original, 'Package installation changed live generation'
        assert not processes(second)
        plan=json.loads(run('farpane-maintenance','plan',second,'--expect-current',first))
        assert sorted(p['role'] for p in plan['processes'])==['gui','server','service']
        result['checks'].append('deb_upgrade_stages_without_touching_real_live_generation')
        run('farpane-maintenance','activate',second,'--expect-current',first,'--maintenance-window')
        assert not processes(first), 'Old generation survived activation'
        observe(second)
        run('farpane-user-integration','bind',second,'--previous',first,user=True)
        launch_gui(second)
        assert snapshot(second)==expected and identity()[0]==credential_hash
        assert unknown.read_bytes()==unknown_before
        result['checks'].append('real_systemd_upgrade_replaces_root_host_gui_preserves_identity_and_entries')

        run('farpane-maintenance','plan',first,'--expect-current',second)
        run('farpane-maintenance','activate',first,'--expect-current',second,'--maintenance-window')
        assert not processes(second), 'Upgraded generation survived rollback'
        observe(first)
        run('farpane-user-integration','rollback',user=True)
        final=launch_gui(first)
        assert snapshot(first)==expected and identity()[0]==credential_hash
        assert unknown.read_bytes()==unknown_before
        result['checks'].append('real_systemd_and_user_entry_rollback_restores_previous_generation')

        run('dpkg','--purge','farpane-native-candidate')
        assert not prefix.exists() and not Path('/usr/bin/farpane-maintenance').exists()
        assert processes(first)==final and snapshot(first)==expected and identity()[0]==credential_hash
        assert run('systemctl','show',unrelated.name,'-p','MainPID','--value')==unrelated_pid
        assert run('systemctl','is-active',unrelated.name).strip()=='active'
        assert unknown.read_bytes()==unknown_before
        result['checks'].append('real_package_purge_retains_running_generation_credentials_and_unrelated_unit')
        result.update(result='pass',initial_artifact=first,upgraded_artifact=second,
                      credential_fields_compared=credential_fields,credentials_unchanged=True,
                      private_packages=marker['maintenance_packages'],network='none',
                      real_remote_connection_tested=False,input_tested=False,gpu_tested=False)
    except Exception:
        result['failure']=traceback.format_exc()
    finally:
        # Only after the separate-kernel and scenario guards succeeded.
        if marker.get('desktop_launch_probe'):
            for path in sorted(OUTPUT.glob('launch-*.png')):
                data=path.read_bytes();assert len(data)<=1024*1024
                print('VM_IMAGE '+path.name+' '+base64.b64encode(data).decode(),flush=True)
        for path in sorted(OUTPUT.glob('*.log')):
            print('VM_LOG '+path.name+' '+json.dumps(path.read_text(errors='replace')[-30000:]),flush=True)
        journal=subprocess.run(['journalctl','-b','--no-pager','-n','180'],capture_output=True,text=True,timeout=5)
        print('VM_SYSTEM_JOURNAL='+json.dumps(journal.stdout),flush=True)
        for home in (Path('/root'),Path(account.pw_dir)):
            for path in sorted((home/'.local/share/logs/FarPane').glob('**/*.log')):
                print('VM_CORE_LOG '+str(path)+' '+json.dumps(path.read_text(errors='replace')[-16000:]),flush=True)
        print('FARPANE_INPUT_VM_RESULT='+json.dumps(result),flush=True)
        os.sync();termios.tcdrain(sys.stdout.fileno())
        subprocess.run(['systemctl','--no-block','poweroff'],check=True,timeout=5)


if __name__=='__main__':
    controller()
