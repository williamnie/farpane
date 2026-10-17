#!/usr/bin/env python3
"""Exercise the real core CLI with fresh private XDG directories, never host config."""
import concurrent.futures
import fcntl
import json
import os
import re
from pathlib import Path
import socket
import subprocess
import tempfile


def run(binary, root):
    env = dict(os.environ)
    for name, suffix in [('XDG_CONFIG_HOME','config'),('XDG_DATA_HOME','data'),('XDG_CACHE_HOME','cache'),('XDG_RUNTIME_DIR','run')]:
        path = root/suffix
        path.mkdir(mode=0o700)
        env[name] = str(path)
    def call(kind, data=None, ok=True):
        command = {'type': kind}
        if data is not None:
            command['data'] = data
        result = subprocess.run([str(binary), '--config-cli'],input=json.dumps(command),capture_output=True,text=True,env=env,timeout=12)
        if ok:
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)
        assert result.returncode != 0, 'unsafe command unexpectedly succeeded'
        return result.stderr
    state = call('snapshot')
    assert state['role']=='config' and not state['host_enabled']
    assert state['authentication']=='approval'
    assert not any(state['sharing']['permissions'][p] for p in ['audio','clipboard','file'])
    assert state['sharing']['permissions']['keyboard']
    identity=state['local_id']
    state=call('set_gpu', {'enabled':True,'retry':False,'revision':state['revision']})
    assert state['gpu_enabled'] and state['revision']==1
    assert 'Configuration changed' in call('set_host',{'enabled':True,'revision':0},ok=False)
    call('set_server',{'settings':{'rendezvous':'not a host','relay':'','public_key':'','force_relay':False},'revision':1},ok=False)
    assert call('snapshot')['revision']==1
    state=call('set_authentication', {'mode':'permanent','password':'synthetic-smoke-password','revision':1})
    assert state['authentication']=='permanent' and state['permanent_password_set'] and state['temporary_password'] is None
    assert 'synthetic-smoke-password' not in json.dumps(state)
    state=call('set_server', {'settings':{'rendezvous':'127.0.0.1:21116','relay':'127.0.0.1:21117','public_key':'','force_relay':True},'revision':2})
    assert state['local_id']==identity and state['revision']==3
    lock=next(root.rglob('.native-owner.lock'))
    with lock.open('r+') as owner:
        fcntl.flock(owner,fcntl.LOCK_EX|fcntl.LOCK_NB)
        call('set_host',{'enabled':True,'revision':3},ok=False)
    assert call('snapshot')['revision']==3
    # Concurrent independent writers cannot both commit the same revision.
    def compete(_):
        result=subprocess.run([str(binary),'--config-cli'],input=json.dumps({'type':'set_gpu','data':{'enabled':False,'retry':False,'revision':3}}),capture_output=True,text=True,env=env,timeout=12)
        return result.returncode==0
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        assert sum(pool.map(compete,range(2)))==1
    state=call('snapshot')
    assert state['revision']==4 and not state['gpu_enabled'] and state['local_id']==identity
    call('approve',{'connection':1,'permissions':{'keyboard':True,'clipboard':False,'audio':False,'file':False}},ok=False)
    assert call('snapshot')['revision']==4
    # Lock file replacement and public permissions fail before config mutation.
    lock.chmod(0o644)
    assert 'Unsafe FarPane configuration lock' in call('snapshot',ok=False)
    lock.chmod(0o600)
    # A persistence failure must not be reported as a successful revision.
    config_dir=lock.parent
    config_dir.chmod(0o500)
    try:
        call('set_host',{'enabled':True,'revision':4},ok=False)
    finally:
        config_dir.chmod(0o700)
    assert call('snapshot')['revision']==4
    assert not (config_dir/'.native-config-transaction.json').exists()
    # Simulate an older FarPane endpoint that predates the native owner lock.
    legacy=Path('/tmp')/f'FarPane-{os.getuid()}'/'ipc'
    legacy.parent.mkdir(mode=0o700,exist_ok=True)
    listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
    listener.bind(str(legacy));listener.listen(1)
    try:
        assert 'existing FarPane runtime is active' in call('set_host',{'enabled':True,'revision':4},ok=False)
    finally:
        listener.close();legacy.unlink()
    assert call('snapshot')['revision']==4
    # Replay a real encrypted two-file record before any Config lazy loads.
    identity_file=config_dir/'FarPane.toml';settings_file=config_dir/'FarPane2.toml'
    original_identity=identity_file.read_bytes();original_settings=settings_file.read_bytes()
    updated=call('set_authentication',{'mode':'temporary','password':'synthetic-recovered-password','revision':4})
    assert updated['revision']==5
    record={'schema':1,'identity':identity_file.read_text(),'settings':settings_file.read_text()}
    assert 'synthetic-recovered-password' not in json.dumps(record)
    identity_file.write_bytes(original_identity);settings_file.write_bytes(original_settings)
    journal=config_dir/'.native-config-transaction.json'
    journal.write_text(json.dumps(record));journal.chmod(0o600)
    recovered=call('snapshot')
    assert recovered['revision']==5 and recovered['authentication']=='temporary' and recovered['local_id']==identity
    assert not journal.exists()
    journal.write_text('{bad sensitive-payload');journal.chmod(0o600)
    error=call('snapshot',ok=False)
    assert 'sensitive-payload' not in error
    journal.unlink()
    assert call('snapshot')['revision']==5
    # Same transaction and revision boundary for public device metadata.
    first=call('snapshot');server=first['server'];rev=first['revision']
    first=call('remember_device',{'peer':'123456789','server':server,'revision':rev})
    assert first['devices'][0]['peer']=='123456789'
    first=call('set_device',{'peer':'123456789','alias':'书房 Linux','favorite':True,'revision':first['revision']})
    assert first['devices'][0]['favorite'] and first['devices'][0]['alias']=='书房 Linux'
    call('forget_device',{'peer':'123456789','revision':rev},ok=False)
    other=dict(server,rendezvous='other-server:21116')
    state=call('set_server',{'settings':other,'revision':first['revision']})
    assert state['devices']==[]
    state=call('remember_device',{'peer':'123456789','server':other,'revision':state['revision']})
    assert state['devices'][0]['alias']=='' and not state['devices'][0]['favorite']
    state=call('set_server',{'settings':server,'revision':state['revision']})
    assert state['devices'][0]['alias']=='书房 Linux' and state['local_id']==identity
    assert state['permanent_password_set'] and state['gpu_enabled']==False
    state=call('forget_device',{'peer':'123456789','revision':state['revision']})
    assert state['devices']==[]
    (root/'device-result.json').write_text(json.dumps({'roundtrip':True,'same_id_server_isolation':True,'alias_favorite':True,'stale_revision_rejected':True,'identity_auth_preserved':True}))
    settings=next(root.rglob('FarPane2.toml'))
    text,count=re.subn(r"(?m)^access-mode\s*=\s*['\"]custom['\"]$", 'access-mode = "full"', settings.read_text())
    assert count==1
    text=text.replace('[options]\n', '[options]\naudio-input = \"Legacy microphone description\"\n',1)
    settings.write_text(text)
    state=call('snapshot')
    assert state['audio_needs_selection'], 'Legacy named input was silently treated as automatic'
    assert all(state['sharing']['permissions'][p] for p in ['keyboard','clipboard','audio'])
    assert not state['sharing']['permissions']['file'], 'Native file access needs an explicit shared root'
    revision=state['revision']
    call('set_host_audio',{'enabled':True,'source':'','microphone':True,'revision':revision},ok=False)
    call('set_host_audio',{'enabled':True,'source':'bad\x00source','microphone':False,'revision':revision},ok=False)
    assert call('snapshot')['revision']==revision
    state=call('set_host_audio',{'enabled':True,'source':'test.monitor','microphone':False,'revision':revision})
    assert state['sharing']['permissions']['audio'] and state['sharing']['audio_source']=='test.monitor'
    assert not state['audio_needs_selection']
    state=call('set_host_audio',{'enabled':False,'source':'test.monitor','microphone':False,'revision':state['revision']})
    assert not state['sharing']['permissions']['audio'] and not state['sharing']['microphone']
    assert all(state['sharing']['permissions'][p] for p in ['keyboard','clipboard'])
    assert not state['sharing']['permissions']['file']
    assert state['local_id']==identity and state['permanent_password_set']
    revision=state['revision']
    call('set_host_files',{'enabled':True,'directory':'relative/path','confirm':True,'revision':revision},ok=False)
    public=root/'public-folder';public.mkdir(mode=0o755)
    call('set_host_files',{'enabled':True,'directory':str(public),'confirm':True,'revision':revision},ok=False)
    assert public.stat().st_mode&0o777==0o755 and call('snapshot')['revision']==revision
    receive=root/'received-files'
    state=call('set_host_files',{'enabled':True,'directory':str(receive),'confirm':True,'revision':revision})
    assert state['sharing']['permissions']['file'] and state['sharing']['receive_directory']==str(receive)
    assert state['sharing']['confirm_files'] and receive.stat().st_mode&0o777==0o700
    assert not state['sharing']['permissions']['audio'] and state['local_id']==identity
    call('confirm_transfer',{'job':1,'accept':True,'overwrite':True},ok=False)
    state=call('set_host_files',{'enabled':False,'directory':str(receive),'confirm':False,'revision':state['revision']})
    assert not state['sharing']['permissions']['file'] and not state['sharing']['confirm_files']
    assert state['sharing']['receive_directory']==str(receive) and receive.is_dir()
    # Native clipboard settings survive fresh CLI processes without changing the
    # legacy runtime's switches or granting rich/image during implicit migration.
    migrated=call('snapshot')['sharing']['clipboard']
    assert migrated['text']=={'send':True,'receive':True}
    assert migrated['rich_text']==migrated['image']=={'send':False,'receive':False}
    legacy_before=re.findall(r'(?m)^(?:access-mode|enable-clipboard)\s*=.*$',settings.read_text())
    before=call('snapshot')
    policy={k:{'send':False,'receive':False} for k in ('text','rich_text','image')}
    policy['image']['receive']=True
    state=call('set_host_clipboard',{'policy':policy,'revision':before['revision']})
    assert call('snapshot')['sharing']['clipboard']==policy
    assert state['sharing']['permissions']['clipboard']
    call('set_host_clipboard',{'policy':policy,'revision':before['revision']},ok=False)
    invalid=dict(policy,unknown=True)
    call('set_host_clipboard',{'policy':invalid,'revision':state['revision']},ok=False)
    assert call('snapshot')['revision']==state['revision']
    assert re.findall(r'(?m)^(?:access-mode|enable-clipboard)\s*=.*$',settings.read_text())==legacy_before
    for key in ('audio_source','microphone','receive_directory','confirm_files'):
        assert state['sharing'][key]==before['sharing'][key]
    assert state['local_id']==identity and state['server']==before['server']
    saved=settings.read_text()
    corrupt,count=re.subn(r'(?m)^farpane-clipboard-policy\s*=.*$', "farpane-clipboard-policy = '{invalid}'",saved)
    assert count==1;settings.write_text(corrupt)
    invalid_state=call('snapshot')
    assert not invalid_state['sharing']['permissions']['clipboard']
    assert all(not any(d.values()) for d in invalid_state['sharing']['clipboard'].values())
    assert '无效' in invalid_state['clipboard_detail']
    settings.write_text(saved)
    assert call('snapshot')['sharing']['clipboard']==policy
    print(json.dumps({'result':'pass' ,'checks':['new-install-defaults','revision-conflict','server-validation','permanent-password-redaction','stable-identity','owner-lock','concurrent-writers','offline-role-boundary','unsafe-lock-permissions','legacy-runtime-migration-guard','failed-persistence-no-false-success','encrypted-journal-recovery','corrupt-journal-refused','device-roundtrip','device-alias-favorite','device-server-isolation','device-stale-revision-rejected','device-forget','audio-source-validation','legacy-audio-selection-not-silently-defaulted','audio-settings-roundtrip','audio-off-overrides-inherited-full-without-changing-other-permissions','file-root-explicit-choice','file-root-validation-no-chmod','file-private-root-create','file-policy-roundtrip','config-role-cannot-confirm-file-task','clipboard-legacy-text-only','clipboard-policy-persisted','clipboard-stale-revision-and-unknown-field-rejected','clipboard-legacy-and-unrelated-options-preserved','clipboard-corrupt-policy-fails-closed']}))

if __name__=='__main__':
    binary=Path('/workspace/Build/Linux/target/release/farpane-core')
    with tempfile.TemporaryDirectory(prefix='farpane-native-config-') as directory:
        run(binary,Path(directory))
