#!/usr/bin/env python3
"""Real native agent/control/GUI smoke. Entrypoint requires isolated container."""
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import time

RELEASE=Path('/opt/farpane-native-test/releases/native-smoke-1')
RUNTIME=Path('/run/farpane-native-test/user')


def stage_release():
    assert os.geteuid()==0 and Path('/.dockerenv').is_file()
    artifact=os.environ.get('FARPANE_NATIVE_TEST_ARTIFACT')
    if artifact:
        source=Path(artifact).resolve(strict=True)
        assert source.is_relative_to(Path('/workspace/Build/Linux/artifacts'))
        sys.path.insert(0,'/workspace/Linux/packaging')
        import native_bundle
        native_bundle.verify(source)
        shutil.copytree(source,RELEASE,symlinks=True)
        native_bundle.verify(RELEASE)
    else:
        RELEASE.joinpath('libexec').mkdir(parents=True)
        shutil.copy2('/workspace/Build/Linux/target/release/farpane-core',RELEASE/'libexec/farpane-core')
        shutil.copy2('/workspace/Build/Linux/native-target/release/farpane',RELEASE/'farpane')
        lock=json.loads(Path('/workspace/Linux/dependencies.lock.json').read_text())
        library='libdrmtap.so.'+lock['libdrmtap']['version']
        (RELEASE/'lib').mkdir()
        shutil.copy2(Path('/workspace/Build/Linux/drmtap-build')/library,RELEASE/'lib'/library)
        (RELEASE/'lib/libdrmtap.so.0').symlink_to(library)


def cli(command, ok=True):
    result=subprocess.run([str(RELEASE/'libexec/farpane-core'),'--config-cli'],input=json.dumps(command),capture_output=True,text=True,timeout=15)
    if ok:
        assert result.returncode==0,result.stderr
        return json.loads(result.stdout)
    assert result.returncode!=0,'Rejected command unexpectedly succeeded'
    return result.stderr


def device_ui(output):
    state=cli({'type':'snapshot'})
    for peer in ['123456789','234567890','345678901']:
        state=cli({'type':'remember_device','data':{'peer':peer,'server':state['server'],'revision':state['revision']}})
    state=cli({'type':'set_device','data':{'peer':'123456789','alias':'书房 Linux','favorite':True,'revision':state['revision']}})
    directory=output/'device-ui';directory.mkdir()
    env=dict(os.environ,FARPANE_DEVICES_SMOKE_DIR=str(directory),GSK_RENDERER='cairo',GTK_A11Y='none')
    with (directory/'gui.log').open('w') as log:
        result=subprocess.run([str(RELEASE/'farpane')],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=35)
    assert result.returncode==0,'Device UI driver failed'
    report=json.loads((directory/'devices-ui.json').read_text())
    assert report['result']=='pass',report
    assert 'CRITICAL' not in (directory/'gui.log').read_text()
    after=cli({'type':'snapshot'})
    assert {d['peer'] for d in after['devices']}=={'234567890','345678901'}
    assert after['revision']==state['revision']+3
    assert after['local_id']==state['local_id'] and after['authentication']==state['authentication']
    return report


def user_test(output):
    core=RELEASE/'libexec/farpane-core'
    initial=cli({'type':'snapshot'})
    assert initial['role']=='config' and not initial['host_enabled']
    # A realistic stored permanent-only mode, using synthetic test data.
    initial=cli({'type':'set_authentication','data':{'mode':'permanent','password':'native-smoke-only','revision':initial['revision']}})
    with (output/'agent.log').open('w') as log:
        agent=subprocess.Popen([str(core),'--server'],stdout=log,stderr=subprocess.STDOUT)
        try:
            socket_path=RUNTIME/'farpane/agent.sock'
            deadline=time.monotonic()+10
            while not socket_path.exists() and time.monotonic()<deadline:
                assert agent.poll() is None,'Agent exited during startup'
                time.sleep(.05)
            assert socket_path.exists(),'Missing agent control endpoint'
            state=cli({'type':'snapshot'})
            assert state['role']=='agent' and state['local_id']==initial['local_id']
            assert state['permanent_password_set'] and state['temporary_password'] is None
            assert socket_path.stat().st_mode & 0o777 == 0o600
            # Same UID alone is insufficient: Python is not the packaged GUI.
            peer=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);peer.settimeout(3);peer.connect(str(socket_path))
            hello=json.dumps({'version':1,'role':'gui','release':RELEASE.name,'session':0}).encode()
            peer.sendall(struct.pack('!I',len(hello))+hello)
            try: assert peer.recv(4)==b'','Untrusted executable received control handshake'
            except ConnectionResetError: pass
            peer.close()
            # A second agent cannot take the config owner or steal its socket.
            duplicate=subprocess.run([str(core),'--server'],capture_output=True,text=True,timeout=5)
            assert duplicate.returncode!=0
            assert agent.poll() is None
            before=state['revision']
            state=cli({'type':'set_gpu','data':{'enabled':True,'retry':False,'revision':before}})
            assert state['role']=='agent' and state['gpu_enabled'] and state['revision']==before+1
            error=cli({'type':'set_host','data':{'enabled':True,'revision':before}},ok=False)
            assert 'Configuration changed' in error
            assert cli({'type':'snapshot'})['revision']==before+1
            device_ui(output)
            # Open/close the real GUI twice. Agent PID and authentication survive.
            for index in range(2):
                directory=output/f'gui-{index}';directory.mkdir()
                env=dict(os.environ,FARPANE_SMOKE_EXIT_SECONDS='5',FARPANE_SMOKE_REPORT_DIR=str(directory),GSK_RENDERER='cairo',GTK_A11Y='none')
                with (directory/'gui.log').open('w') as log_gui:
                    gui=subprocess.run([str(RELEASE/'farpane')],env=env,stdout=log_gui,stderr=subprocess.STDOUT,timeout=15)
                assert gui.returncode==0
                assert agent.poll() is None,'Closing GUI terminated Host'
                for page in range(3):
                    assert (directory/f'page-{page}.png').read_bytes().startswith(b'\x89PNG')
                    ui_state=json.loads((directory/f'page-{page}-state.json').read_text())
                    assert ui_state['role']=='agent' and ui_state['permanent_password_set'] and not ui_state['temporary_password_present']
                    maps=(directory/f'page-{page}-maps.txt').read_text().lower()
                    assert not any(lib in maps for lib in ['libgtk-3','libgdk-3','libflutter','libsciter','libappindicator'])
                assert 'CRITICAL' not in (directory/'gui.log').read_text()
                state=cli({'type':'snapshot'})
                assert state['role']=='agent' and state['local_id']==initial['local_id'] and state['temporary_password'] is None
            maps=Path(f'/proc/{agent.pid}/maps').read_text();(output/'agent-maps.txt').write_text(maps)
            (output/'agent-memory.txt').write_text(Path(f'/proc/{agent.pid}/smaps_rollup').read_text())
            assert not any(lib in maps.lower() for lib in ['libgtk-3','libgdk-3','libflutter','libsciter','libappindicator'])
        finally:
            agent.terminate()
            try:agent.wait(timeout=5)
            except subprocess.TimeoutExpired:agent.kill();agent.wait()
    directory=output/'gui-offline';directory.mkdir()
    env=dict(os.environ,FARPANE_SMOKE_EXIT_SECONDS='5',FARPANE_SMOKE_REPORT_DIR=str(directory),GSK_RENDERER='cairo',GTK_A11Y='none')
    with (directory/'gui.log').open('w') as log_gui:
        gui=subprocess.run([str(RELEASE/'farpane')],env=env,stdout=log_gui,stderr=subprocess.STDOUT,timeout=15)
    assert gui.returncode==0
    for page in range(3):
        state=json.loads((directory/f'page-{page}-state.json').read_text())
        assert state['role']=='config' and state['permanent_password_set'] and not state['temporary_password_present']
    assert cli({'type':'snapshot'})['local_id']==initial['local_id']
    print(json.dumps({'result':'pass','checks':['cm-ready-before-host','online-config-forward','release-peer-authentication','exclusive-agent','revision-conflict-reply','gui-close-retains-host','gui-offline-config-helper','permanent-only-state','no-legacy-gui-maps'],'network':'none','gpu':'none','display':'private-xvfb','connection_media_test':False}))


def container_setup(output,uid,gid):
    assert os.geteuid()==0 and Path('/.dockerenv').exists(), 'Only use in the isolated test container'
    stage_release()
    RUNTIME.mkdir(mode=0o700,parents=True);os.chown(RUNTIME,uid,gid)
    output.mkdir(parents=True,exist_ok=True);os.chown(output,uid,gid)
    env=dict(os.environ,XDG_RUNTIME_DIR=str(RUNTIME),RUSTDESK_FORCED_DISPLAY_SERVER='x11')
    for name,suffix in [('XDG_CONFIG_HOME','config'),('XDG_DATA_HOME','data'),('XDG_CACHE_HOME','cache'), ('XDG_STATE_HOME','state')]:
        directory=RUNTIME/suffix;directory.mkdir(mode=0o700);os.chown(directory,uid,gid);env[name]=str(directory)
    result=subprocess.run(['setpriv','--reuid',str(uid),'--regid',str(gid),'--clear-groups','dbus-run-session','--','xvfb-run','-a','-s','-screen 0 1280x900x24','python3',__file__,'--user',str(output)],env=env)
    sys.exit(result.returncode)

if __name__=='__main__':
    if sys.argv[1]=='--user':user_test(Path(sys.argv[2]))
    else:container_setup(Path(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3]))
