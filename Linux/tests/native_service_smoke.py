"""Real native root/user roles, controlled loginctl and private X11/user bus."""
import json
import os
from pathlib import Path
import pwd
import shutil
import signal
import socket
import subprocess
import sys
import time
import traceback

from native_host_smoke import stage_release, RELEASE

ROOT=Path('/workspace')
PRIVATE=Path('/run/farpane-service-test')
FIXTURE=Path('/opt/farpane-service-fixture')
CORE=RELEASE/'libexec/farpane-core'
PANELS={}
LEADERS={}
SESSION_IDS={1000:'private-1000',1001:'private-1001'}


def wait_for(predicate,seconds=12):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        value=predicate()
        if value:return value
        time.sleep(.1)
    raise TimeoutError('Service fixture condition did not arrive')


def roles():
    result=[]
    for path in Path('/proc').iterdir():
        if not path.name.isdecimal():continue
        try:
            if path.joinpath('exe').readlink()!=CORE:continue
            args=path.joinpath('cmdline').read_bytes().split(b'\0')
            if len(args)>1:result.append({'pid':int(path.name),'uid':path.stat().st_uid,'role':args[1].decode()})
        except (FileNotFoundError,ProcessLookupError):pass
    return result


def session(uid):
    value={} if uid is None else {'sid':SESSION_IDS[uid],'uid':uid,'name':pwd.getpwuid(uid).pw_name,'display':':92','leader':LEADERS[uid].pid}
    temporary=PRIVATE/'session-new.json';temporary.write_text(json.dumps(value));temporary.replace(PRIVATE/'session.json')


def user_env(uid):
    return {'PATH':'/usr/bin:/bin','HOME':pwd.getpwuid(uid).pw_dir,'USER':pwd.getpwuid(uid).pw_name,
            'XDG_RUNTIME_DIR':'/run/user/'+str(uid),'DISPLAY':':92','XAUTHORITY':'/run/user/'+str(uid)+'/test.Xauthority',
            'DBUS_SESSION_BUS_ADDRESS':'unix:path=/run/user/'+str(uid)+'/bus','XDG_SESSION_TYPE':'x11','XDG_SESSION_CLASS':'user',
            'XDG_SESSION_ID':SESSION_IDS[uid],'XDG_CONFIG_HOME':'/run/user/'+str(uid)+'/session-config',
            'RUSTDESK_FORCED_DISPLAY_SERVER':'x11','GTK_A11Y':'none','GSK_RENDERER':'cairo'}


def user_command(uid,*args):
    return ['setpriv','--reuid='+str(uid),'--regid='+str(pwd.getpwuid(uid).pw_gid),'--clear-groups',*map(str,args)]


def managed_env(uid):
    return {key:value for key,value in user_env(uid).items() if key!='XDG_SESSION_ID'}


def cli(uid,command):
    result=subprocess.run(user_command(uid,CORE,'--config-cli'),env=user_env(uid),input=json.dumps(command),
                          capture_output=True,text=True,check=True,timeout=15)
    return json.loads(result.stdout)


def agent_state(uid):
    try:
        # A config helper must not race the new agent for its first owner lock.
        # Only query once the real agent listener accepts a connection; a stale
        # socket file after SIGKILL is insufficient.
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as probe:
            probe.settimeout(.2);probe.connect('/run/user/'+str(uid)+'/farpane/agent.sock')
        value=cli(uid,{'type':'snapshot'})
        return value if value['role']=='agent' else None
    except (OSError,subprocess.CalledProcessError,subprocess.TimeoutExpired):return None


def agent_pid(uid):
    found=[p['pid'] for p in roles() if p['role']=='--server' and p['uid']==uid]
    assert len(found)<=1,'Overlapping Hosts for a desktop user'
    return found[0] if found else None


def legacy_probe(uid,kind,content=None):
    body=json.dumps({'t':kind,'c':content},separators=(',',':')).encode()
    width=next(n for n in range(1,5) if len(body)<(1<<(n*8-2)))
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as connection:
        connection.settimeout(2)
        def exact(size):
            result=b''
            while len(result)<size:
                chunk=connection.recv(size-len(result))
                if not chunk:raise EOFError()
                result+=chunk
            return result
        try:
            connection.connect('/tmp/FarPane-'+str(uid)+'/ipc')
            connection.sendall(((len(body)<<2)|(width-1)).to_bytes(width,'little')+body)
            head=exact(1);head+=exact(head[0]&3)
            size=int.from_bytes(head,'little')>>2
            assert size<=4096,'Observation response exceeds expected bound'
            return json.loads(exact(size))
        except (EOFError,PermissionError,FileNotFoundError,ConnectionRefusedError,ConnectionResetError,BrokenPipeError):return None


def main(output,uid,gid):
    assert Path('/.dockerenv').exists() and os.geteuid()==0
    assert not Path('/dev/dri').exists() and not os.environ.get('DISPLAY')
    assert os.environ.get('FARPANE_SERVICE_TEST_ISOLATED')=='1'
    os.umask(0o022);output.mkdir(parents=True,exist_ok=False)
    PRIVATE.mkdir(mode=0o755);FIXTURE.mkdir(mode=0o755)
    stage_release();session(None)
    helper=FIXTURE/'loginctl';shutil.copyfile(ROOT/'Linux/tests/native_service_loginctl.py',helper);helper.chmod(0o755)
    panel=FIXTURE/'xfce4-panel'
    subprocess.run(['cc','-O2',str(ROOT/'Linux/tests/native_install_fixture.c'),'-o',str(panel)],check=True)
    children=[];logs=[];service=None;checks=[]
    def launch(name,args,env=None):
        log=(output/(name+'.log')).open('w');logs.append(log)
        process=subprocess.Popen(args,env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
        children.append(process);return process
    try:
        try:pwd.getpwuid(1001)
        except KeyError:subprocess.run(['useradd','--uid','1001','--user-group','--create-home','--shell','/bin/sh','farpane-second'],check=True)
        buses={}
        def start_bus(user,suffix=''):
            bus=launch('user-bus-'+str(user)+suffix,user_command(user,'dbus-daemon','--session','--nofork',
                       '--address=unix:path=/run/user/'+str(user)+'/bus'),managed_env(user))
            wait_for(lambda:Path('/run/user/'+str(user)+'/bus').is_socket())
            return bus
        for user in (1000,1001):
            account=pwd.getpwuid(user);runtime=Path('/run/user/'+str(user))
            runtime.mkdir(parents=True,mode=0o700);os.chown(runtime,user,account.pw_gid)
            config=runtime/'session-config';config.mkdir(mode=0o700);os.chown(config,user,account.pw_gid)
            auth=runtime/'test.Xauthority';auth.write_bytes(b'');auth.chmod(0o600);os.chown(auth,user,account.pw_gid)
            buses[user]=start_bus(user)
            leader_env={key:value for key,value in user_env(user).items() if key not in ('DISPLAY','XAUTHORITY','DBUS_SESSION_BUS_ADDRESS')}
            LEADERS[user]=launch('session-leader-'+str(user),user_command(user,panel),leader_env)
            PANELS[user]=launch('session-environment-'+str(user),user_command(user,panel),managed_env(user))
        display=launch('private-display',user_command(1000,'Xvfb',':92','-screen','0','640x480x24','-nolisten','tcp','-ac'),managed_env(1000))
        wait_for(lambda:Path('/tmp/.X11-unix/X92').is_socket())
        initial=cli(1000,{'type':'snapshot'})
        second_initial=cli(1001,{'type':'snapshot'})
        assert initial['role']=='config' and not initial['host_enabled']
        session(1000)
        root_home=PRIVATE/'root-home';root_home.mkdir(mode=0o700)
        root_env={'PATH':str(FIXTURE)+':/usr/bin:/bin','HOME':str(root_home),
                  'XDG_CONFIG_HOME':str(root_home/'config'),'XDG_DATA_HOME':str(root_home/'data'),
                  'RUSTDESK_FORCED_DISPLAY_SERVER':'x11','RUST_LOG':'info'}
        state_path=PRIVATE/'session.json';original=json.loads(state_path.read_text())
        state_path.write_text(json.dumps(original|{'extra_sessions':[original|{'sid':'another-login','active':'no','state':'online'}]}))
        preflight=launch('ambiguous-session-service',[str(CORE),'--service'],root_env)
        time.sleep(3.5)
        assert preflight.poll() is None and agent_pid(1000) is None
        state_path.write_text(json.dumps(original))
        wait_for(lambda:agent_state(1000),seconds=15)
        assert agent_state(1000)['local_id']==initial['local_id']
        preflight.terminate();preflight.wait(timeout=5)
        wait_for(lambda:agent_pid(1000) is None)
        checks.append('untagged_desktop_services_require_one_graphical_login')
        adopted=launch('preexisting-agent',user_command(1000,CORE,'--server'),user_env(1000));wait_for(lambda:agent_state(1000))
        # Real EPERM from the kernel, not a mocked stop method: remove only
        # CAP_KILL from this test service. The parent harness retains it for
        # cleanup. A desktop switch must not start a second user's Host.
        denied=launch('root-without-kill',['setpriv','--bounding-set=-kill',str(CORE),'--service'],root_env)
        time.sleep(2);assert denied.poll() is None and agent_pid(1000)==adopted.pid
        session(1001);time.sleep(3)
        assert denied.poll() is None and agent_pid(1000)==adopted.pid and agent_pid(1001) is None
        denied.terminate();denied.wait(timeout=8)
        assert adopted.poll() is None
        checks.append('real_stop_permission_failure_blocks_new_user_context')
        session(1000)
        previous_user=launch('previous-user-agent',user_command(1001,CORE,'--server'),user_env(1001));wait_for(lambda:agent_state(1001))
        service=launch('root-service',[str(CORE),'--service'],root_env)
        wait_for(lambda:previous_user.poll() is not None,seconds=15)
        state=wait_for(lambda:agent_state(1000))
        assert state['role']=='agent' and state['local_id']==initial['local_id']
        assert agent_pid(1000)==adopted.pid
        checks.append('root_adopted_matching_agent_and_retired_other_user')
        adopted.kill();adopted.wait(timeout=3)
        wait_for(lambda:agent_pid(1000) not in (None,adopted.pid),seconds=12)
        state=wait_for(lambda:agent_state(1000));first_pid=agent_pid(1000)
        assert state['local_id']==initial['local_id']
        env=dict(v.split(b'=',1) for v in Path('/proc/'+str(first_pid)+'/environ').read_bytes().split(b'\0') if b'=' in v)
        assert env[b'HOME']==os.fsencode(pwd.getpwuid(1000).pw_dir)
        assert env[b'XDG_CONFIG_HOME']==b'/run/user/1000/session-config' and env[b'DBUS_SESSION_BUS_ADDRESS']==b'unix:path=/run/user/1000/bus'
        assert env[b'XDG_SESSION_ID']==SESSION_IDS[1000].encode()
        status=dict(line.split(':',1) for line in Path('/proc/'+str(first_pid)+'/status').read_text().splitlines())
        assert set(status['Uid'].split())=={'1000'} and int(status['CapEff'].strip(),16)==0 and status['NoNewPrivs'].strip()=='1'
        expected_groups=set(subprocess.check_output(['id','-G',pwd.getpwuid(1000).pw_name],text=True).split())
        assert set(status['Groups'].split())==expected_groups
        checks.append('direct_spawn_without_sudo_sanitized_environment_and_credentials')
        health=wait_for(lambda:legacy_probe(1000,'NativeHealth'))
        activity=legacy_probe(1000,'NativeActivity')
        assert health=={'t':'NativeHealth','c':True},health
        assert activity['t']=='NativeActivity' and activity['c']['schema']==1,activity
        start=int(Path('/proc/'+str(first_pid)+'/stat').read_text().rsplit(') ',1)[1].split()[19])
        assert activity['c']['process_start']==start and activity['c']['generation']>0
        assert legacy_probe(1000,'Config',['id',None]) is None
        for user in (1000,1001):
            rejected=subprocess.run(user_command(user,sys.executable,__file__,'--probe','1000','NativeHealth'),
                capture_output=True,text=True,check=True,timeout=5)
            assert json.loads(rejected.stdout) is None
        (output/'observations.json').write_text(json.dumps({'health':health,'activity':activity},indent=2)+'\n')
        checks.append('root_observations_work_and_reject_commands_and_untrusted_users')
        wait_for(lambda:agent_state(1000)['desktop']['connected'])
        checks.append('x11_user_bus_connected')
        gui_output=output/'gui';gui_output.mkdir();os.chown(gui_output,1000,pwd.getpwuid(1000).pw_gid)
        gui=launch('gui',user_command(1000,RELEASE/'farpane'),user_env(1000)|{
            'FARPANE_SMOKE_EXIT_SECONDS':'5','FARPANE_SMOKE_REPORT_DIR':str(gui_output)})
        assert gui.wait(timeout=20)==0
        assert (gui_output/'page-0.png').exists() and agent_pid(1000)==first_pid
        checks.append('real_gui_open_close_keeps_supervised_agent')
        state=agent_state(1000)
        for enabled in (True,False):
            state=cli(1000,{'type':'set_host','data':{'enabled':enabled,'revision':state['revision']}})
            assert state['host_enabled']==enabled and state['role']=='agent'
            time.sleep(.6)
            assert service.poll() is None and agent_pid(1000)==first_pid
        checks.append('host_enable_disable_keeps_root_and_control_agent')
        buses[1000].terminate();buses[1000].wait(timeout=3)
        wait_for(lambda:not agent_state(1000)['desktop']['connected'])
        buses[1000]=start_bus(1000,'-restarted')
        wait_for(lambda:agent_state(1000)['desktop']['connected'])
        assert agent_pid(1000)==first_pid
        checks.append('user_bus_restart_reconnects_without_host_restart')
        for fault in ('error','malformed','hang'):
            state_path=PRIVATE/'session.json';original=json.loads(state_path.read_text())
            state_path.write_text(json.dumps(original|{'fault':fault}))
            time.sleep(2)
            assert service.poll() is None and agent_pid(1000)==first_pid
            assert agent_state(1000)['local_id']==initial['local_id']
            state_path.write_text(json.dumps(original));time.sleep(1)
            assert service.poll() is None and agent_pid(1000)==first_pid
        checks.append('failed_malformed_and_hung_session_queries_retain_host_and_recover')
        old_pid=first_pid
        PANELS[1000].terminate();PANELS[1000].wait(timeout=3)
        LEADERS[1000].terminate();LEADERS[1000].wait(timeout=3)
        SESSION_IDS[1000]='private-1000-second-login'
        leader_env={key:value for key,value in user_env(1000).items() if key not in ('DISPLAY','XAUTHORITY','DBUS_SESSION_BUS_ADDRESS')}
        LEADERS[1000]=launch('session-leader-1000-relogin',user_command(1000,panel),leader_env)
        PANELS[1000]=launch('session-environment-1000-relogin',user_command(1000,panel),managed_env(1000))
        session(1000)
        wait_for(lambda:agent_pid(1000) not in (None,old_pid),seconds=15)
        wait_for(lambda:agent_state(1000))
        first_pid=agent_pid(1000)
        assert agent_state(1000)['local_id']==initial['local_id']
        env=Path('/proc/'+str(first_pid)+'/environ').read_bytes().split(b'\0')
        assert b'XDG_SESSION_ID=private-1000-second-login' in env
        checks.append('same_uid_new_login_ends_old_host_and_preserves_identity')
        service.kill();service.wait(timeout=3)
        wait_for(lambda:agent_pid(1000) is None,seconds=5)
        checks.append('parent_death_does_not_leave_orphan_agent')
        service=launch('root-service-restarted',[str(CORE),'--service'],root_env)
        wait_for(lambda:agent_state(1000),seconds=15)
        healthy_pid=agent_pid(1000);healthy_started=time.monotonic()
        print('Testing healthy agent survives beyond the 60-second recovery threshold',flush=True)
        while time.monotonic()-healthy_started<70:
            assert service.poll() is None and agent_pid(1000)==healthy_pid,'Healthy Host was incorrectly restarted'
            time.sleep(.5)
        checks.append('healthy_agent_survives_70s_without_false_recovery')
        before_fault=agent_pid(1000);started=time.monotonic();os.kill(before_fault,signal.SIGSTOP)
        print('Testing real 60-second sustained health timeout against stopped agent',flush=True)
        # Actual wall time and authenticated IPC probes, not an accelerated
        # policy clock. SIGKILL recovery is confined to this owned process.
        wait_for(lambda:agent_pid(1000) not in (None,before_fault),seconds=85)
        fault_elapsed=time.monotonic()-started
        assert fault_elapsed>=60,fault_elapsed
        wait_for(lambda:agent_state(1000))
        checks.append('sustained_60s_health_failure_recovers_real_agent')
        old_pid=agent_pid(1000);session(1001)
        wait_for(lambda:agent_state(1001),seconds=15)
        assert agent_pid(1000) is None and agent_state(1001)['local_id']==second_initial['local_id']
        assert cli(1000,{'type':'snapshot'})['local_id']==initial['local_id']
        checks.append('user_switch_ends_old_authorization_before_new_agent')
        session(None)
        wait_for(lambda:not any(p['role']=='--server' for p in roles()),seconds=12)
        assert service.poll() is None
        checks.append('no_desktop_session_stops_agents_but_keeps_service')
        session(1000);wait_for(lambda:agent_state(1000),seconds=15)
        print(json.dumps({'checks':checks,'roles':roles(),'desktop':state['desktop']}),flush=True)
        service.terminate();service.wait(timeout=8)
        wait_for(lambda:not any(p['role']=='--server' for p in roles()),seconds=5)
        checks.append('root_exit_reaped_agent')
        (output/'result.json').write_text(json.dumps({'result':'pass','checks':checks,'session_provider':'controlled loginctl; not real logind',
            'root_core_real':True,'host_touched':False,'unresponsive_recovery_seconds':fault_elapsed},indent=2)+'\n')
    except BaseException:
        (output/'error.txt').write_text(traceback.format_exc())
        (output/'failure-roles.json').write_text(json.dumps(roles(),indent=2)+'\n')
        raise
    finally:
        for process in reversed(children):
            if process.poll() is None:
                process.terminate()
                try:process.wait(timeout=3)
                except subprocess.TimeoutExpired:process.kill();process.wait(timeout=3)
        # Only exact executable processes in this private PID namespace.
        for process in roles():
            try:os.kill(process['pid'],signal.SIGKILL)
            except ProcessLookupError:pass
        for log in logs:log.close()
        for prefix,home in [('root',PRIVATE/'root-home'),('root-passwd',Path('/root')),
                            ('user',Path(pwd.getpwuid(1000).pw_dir)),('second-user',Path(pwd.getpwuid(1001).pw_dir))]:
            for path in (home/'.local/share/logs/FarPane').rglob('*.log'):
                destination=output/'internal-logs'/prefix/path.relative_to(home)
                destination.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,destination)
        for path in [output,*output.rglob('*')]:os.chown(path,uid,gid)


if __name__=='__main__':
    if sys.argv[1]=='--probe':print(json.dumps(legacy_probe(int(sys.argv[2]),sys.argv[3])))
    else:main(Path(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3]))
