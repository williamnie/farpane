"""Actual native file session in the existing private display/network harness."""
import hashlib,json,os,socket,subprocess,threading,time
from pathlib import Path
from native_host_smoke import cli,RELEASE,RUNTIME

class SlowLink:
    """One bounded loopback relay, only inside this test's network namespace."""
    def __init__(self):
        self.stop=threading.Event();self.sockets=[];self.pumps=[]
        self.listener=socket.socket();self.listener.bind(('127.0.0.1',21119));self.listener.listen(1);self.listener.settimeout(.2)
        self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()
    def run(self):
        try:
            while not self.stop.is_set():
                try:client,_=self.listener.accept();break
                except socket.timeout:continue
            else:return
            host=socket.create_connection(('127.0.0.1',21118),timeout=2)
            self.sockets=[client,host]
            for s in self.sockets:s.settimeout(.2)
            for source,destination in [(client,host),(host,client)]:
                t=threading.Thread(target=self.pump,args=(source,destination),daemon=True);self.pumps.append(t);t.start()
            for t in self.pumps:t.join()
        except OSError:pass
    def pump(self,source,destination):
        try:
            while not self.stop.is_set():
                try:data=source.recv(65536)
                except socket.timeout:continue
                if not data:break
                destination.sendall(data)
                self.stop.wait(.02)
        except OSError:pass
        finally:
            self.stop.set()
            for s in self.sockets:
                try:s.shutdown(socket.SHUT_RDWR)
                except OSError:pass
    def close(self):
        self.stop.set();self.listener.close()
        for s in self.sockets:s.close()
        self.thread.join(timeout=3)
        assert not self.thread.is_alive(),'Private relay failed to exit'

def setup_files(output):
    root=RUNTIME/'shared-files';root.mkdir(mode=0o700)
    for i in range(1000):(root/f'entry-{i:04}.txt').write_bytes(b'')
    state=cli({'type':'snapshot'})
    state=cli({'type':'set_host_files','data':{'enabled':True,'directory':str(root),'confirm':True,'revision':state['revision']}})
    assert state['sharing']['permissions']['file'] and state['sharing']['confirm_files']
    (output/'file-shared-root.txt').write_text(str(root))

def exercise_files(output,agent,auth_driver=None):
    matrix=os.environ.get('FARPANE_NATIVE_TEST_MODE')=='files-matrix'
    tree=os.environ.get('FARPANE_NATIVE_TEST_MODE')=='files-tree'
    fault=os.environ.get('FARPANE_NATIVE_TEST_MODE')=='files-tree-fault'
    directory=output/'file-ui';directory.mkdir()
    (directory/'downloads').mkdir(mode=0o700)
    # Non-empty multi-block payload, plus a request intentionally cancelled before consent.
    empty=os.environ.get('FARPANE_NATIVE_TEST_MODE')=='files-empty'
    source=directory/'upload.bin';source.write_bytes(b'' if empty else bytes(i%251 for i in range(128*1024*3+17)))
    (directory/'cancel.bin').write_bytes(b'cancelled-fixture'*1024)
    if matrix:
        (directory/'replacement').mkdir()
        (directory/'replacement/upload.bin').write_bytes(b'replacement-content'*32768)
        (directory/'interrupted.bin').write_bytes(b'\x5a'*(16*1024*1024))
    if tree:
        selected=directory/'tree';selected.mkdir()
        (selected/'nested/empty').mkdir(parents=True)
        for i in range(300):(selected/'nested'/f'entry-{i:04}.bin').write_bytes(bytes([i%251])*(i%300+1))
        (selected/'.hidden').write_bytes(b'hidden file included in explicit folder selection')
        (selected/'outside').symlink_to('../upload.bin')
        (directory/'empty-folder').mkdir()
        (directory/'multi').mkdir()
        for name,data in [('a.bin',b'multiple files'),('b.bin',b'\x35'*(128*1024+17)),('空.bin',b'')]:
            (directory/'multi'/name).write_bytes(data)
    root=RUNTIME/'shared-files'
    if fault:
        (directory/'recovery').mkdir(mode=0o700)
        for name in ['changing','cancel-tree']:
            folder=root/name;folder.mkdir()
            (folder/'large.bin').write_bytes(b'\x5a'*(32*1024*1024))
        (directory/'upload-changing.bin').write_bytes(b'\x35'*(32*1024*1024))
    relay=SlowLink() if matrix or fault else None
    sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
    original=sha(source)
    root=RUNTIME/'shared-files';received=directory/'downloads/FarPane/upload.bin'
    before=cli({'type':'snapshot'})
    env=dict(os.environ,DISPLAY=':92',FARPANE_FILES_SMOKE_DIR=str(directory),GSK_RENDERER='cairo',GTK_A11Y='none')
    if auth_driver is not None:env['FARPANE_NATIVE_TEST_MODE']='files-secrets'
    with (directory/'gui.log').open('w') as log:
        gui=subprocess.Popen([str(RELEASE/'farpane')],env=env,stdout=log,stderr=subprocess.STDOUT)
        sampled=False;deadline=time.monotonic()+65
        try:
            while gui.poll() is None:
                assert time.monotonic()<deadline,'File GUI test timed out'
                try:progress=json.loads((directory/'files-progress.json').read_text())
                except (FileNotFoundError,json.JSONDecodeError):progress={}
                if auth_driver is not None:auth_driver(directory,gui,progress)
                if fault and progress.get('stage')==30 and not (directory/'source-changed').exists():
                    if any(j[0]==4 and j[3]>0 for j in progress.get('jobs',[])):
                        (root/'changing/large.bin').write_bytes(b'changed while directory download was active')
                        (directory/'source-changed').touch()
                if fault and progress.get('stage')==33 and not (directory/'upload-source-changed').exists():
                    if any(t['name'].endswith('upload-changing.bin') and t['done']>0 for t in progress.get('host_tasks',[])):
                        (directory/'upload-changing.bin').write_bytes(b'changed while upload was active')
                        (directory/'upload-source-changed').touch()
                if tree and progress.get('stage')==22 and (root/'empty-folder').is_dir():
                    if not (root/'tree/outside').is_symlink():(root/'tree/outside').symlink_to('../upload.bin')
                    (directory/'download-tree-ready').touch()
                if tree and progress.get('stage')==24 and not (directory/'tree-overwrite-ready').exists():
                    (directory/'downloads/FarPane/tree/.hidden').write_bytes(b'local original must survive until explicit consent')
                    (directory/'tree-overwrite-ready').touch()
                if tree and progress.get('stage')==25 and any(j[0]==9 and j[5] for j in progress.get('jobs',[])):
                    assert (directory/'downloads/FarPane/tree/.hidden').read_bytes()==b'local original must survive until explicit consent'
                    (directory/'tree-local-preserved').touch()
                if matrix and progress.get('stage')==8:
                    assert sha(root/'upload.bin')==sha(received)==original,'Reject replaced an existing file'
                    (directory/'rejected-preserved').touch()
                if matrix and progress.get('stage')==11 and any(j[0]==6 and j[5] for j in progress.get('jobs',[])):
                    assert sha(received)==original,'Download replaced a file before consent'
                    (directory/'local-preserved').touch()
                if not sampled and progress.get('stage',0) in [3,4,5]:
                    from native_viewer_smoke import sample_processes
                    sample_processes(directory,gui,agent)
                    report=json.loads((directory/'process-sample.json').read_text());report['backend']='file-only';
                    (directory/'process-sample.json').write_text(json.dumps(report,indent=2))
                    sampled=True
                time.sleep(.05)
        finally:
            if gui.poll() is None:gui.terminate()
            gui.wait(timeout=5)
            if relay:relay.close()
    assert gui.returncode==0,gui.returncode
    report=json.loads((directory/'files-ui.json').read_text());assert report['result']=='pass',report
    assert sampled,'File worker was not sampled'
    final_source=directory/'replacement/upload.bin' if matrix else source
    hashes={name:sha(path) for name,path in [('source',final_source),('host',root/'upload.bin'),('download',received)]}
    assert len(set(hashes.values()))==1,hashes
    assert not (root/'cancel.bin').exists()
    assert not (root/'interrupted.bin').exists()
    if tree:
        selected=directory/'tree';target=root/'tree'
        manifest=lambda base:{str(p.relative_to(base)):sha(p) for p in base.rglob('*') if p.is_file() and not p.is_symlink()}
        downloaded=directory/'downloads/FarPane/tree'
        expected=manifest(selected);actual=manifest(target);saved=manifest(downloaded);assert expected==actual==saved
        assert len(expected)==301 and (target/'nested/empty').is_dir()
        assert (target/'outside').is_symlink() and (root/'empty-folder').is_dir()
        assert not (downloaded/'outside').exists() and (downloaded/'nested/empty').is_dir()
        assert (directory/'downloads/FarPane/empty-folder').is_dir()
        assert (directory/'tree-local-preserved').exists()
        for p in (directory/'multi').iterdir():assert sha(p)==sha(root/p.name)
        progress=json.loads((directory/'files-progress.json').read_text())
        task=next(t for t in progress['host_tasks'] if t['name']=='tree')
        assert task['status']=='completed' and task['done']==task['total']==sum(p.stat().st_size for p in selected.rglob('*') if p.is_file() and not p.is_symlink())
        assert not (directory/'host-notice.json').exists()
        (directory/'tree-result.json').write_text(json.dumps({'result':'pass','files':len(expected),'source_hashes':expected,'destination_hashes':actual,'download_hashes':saved,'single_folder_approval':True,'empty_directories_preserved':True,'symlink_not_followed':True,'multiple_files_hashes_match':True,'directory_download_overwrite_confirmed':True},indent=2))
    if matrix:
        assert (directory/'rejected-preserved').exists() and (directory/'local-preserved').exists()
        assert not (directory/'host-notice.json').exists(),(directory/'host-notice.json').read_text()
    if fault:
        assert (directory/'source-changed').exists() and (directory/'upload-source-changed').exists()
        assert not (directory/'downloads/FarPane/changing/large.bin').exists()
        assert not (directory/'downloads/FarPane/cancel-tree/large.bin').exists()
        assert not (root/'upload-changing.bin').exists()
        assert sha(directory/'recovery/FarPane/upload.bin')==original
        assert not (directory/'host-notice.json').exists()
        (directory/'fault-result.json').write_text(json.dumps({'result':'pass','source-change-during-directory-download':True,'source-change-during-upload':True,'cancel-active-directory-download':True,'same-worker-recovery-transfer':True,'unfinished-files-not-committed':True},indent=2))
    assert not list(root.rglob('.farpane-part-*'))
    assert not list((directory/'downloads').rglob('.farpane-part-*'))
    assert agent.poll() is None
    after=cli({'type':'snapshot'})
    (directory/'host-final-tasks.json').write_text(json.dumps(after['file_tasks'],indent=2))
    for key in ['local_id','revision','host_enabled','authentication','permanent_password_set','server','sharing','gpu_enabled','devices']:
        assert before[key]==after[key],key
    assert not after['inbound'],after['inbound']
    assert 'CRITICAL' not in (directory/'gui.log').read_text()
    (directory/'result.json').write_text(json.dumps({'result':'pass','hashes':hashes,'cancel_preserves_destination':True,'host_retained':True,'configuration_unchanged':True,'no_partial_files':True},indent=2))
    print(json.dumps({'result':'pass','checks':report['checks']+['upload-download-sha256-match','host-config-preserved','no-partial-files']+(['empty-file-roundtrip'] if empty else []),'network':'isolated-loopback','display':'two-private-xvfb','gpu':'none'}))
