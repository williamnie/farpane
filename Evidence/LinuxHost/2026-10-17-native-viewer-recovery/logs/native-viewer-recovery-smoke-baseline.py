"""Actual bounded Viewer recovery through a private TCP proxy and private keyring."""
import json,os,select,socket,threading,time
from pathlib import Path
from gi.repository import GLib,Secret
from native_host_smoke import cli,RELEASE
from native_desktop_smoke import wait,read
from native_recovery_smoke import Providers
from native_secrets_smoke import PrivateSecrets,SCHEMA,attributes

PEER='127.0.0.1:21119'
class Proxy:
    def __init__(self):
        self.listener=socket.socket();self.listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        self.listener.bind(('127.0.0.1',21119));self.listener.listen();self.listener.settimeout(.2)
        self.lock=threading.Lock();self.active={};self.records=[];self.workers=[];self.stop=False;self.drop_new=False
        self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()
    def run(self):
        while not self.stop:
            try:client,_=self.listener.accept()
            except socket.timeout:continue
            serial=len(self.records);self.records.append({'serial':serial,'at':time.monotonic(),'drop':self.drop_new})
            if self.drop_new:client.close();continue
            try:remote=socket.create_connection(('127.0.0.1',21118),timeout=2)
            except OSError:client.close();continue
            remote.settimeout(None)
            with self.lock:self.active[serial]=(client,remote)
            worker=threading.Thread(target=self.forward,args=(serial,client,remote),daemon=True)
            self.workers.append(worker);worker.start()
    def forward(self,serial,client,remote):
        try:
            while not self.stop:
                ready,_,_=select.select([client,remote],[],[],.2)
                for source in ready:
                    data=source.recv(65536)
                    if not data:return
                    (remote if source is client else client).sendall(data)
        except (OSError,ValueError):pass
        finally:
            with self.lock:self.active.pop(serial,None)
            client.close();remote.close()
    def cut(self):
        with self.lock:pairs=list(self.active.values())
        for pair in pairs:
            for s in pair:
                try:s.shutdown(socket.SHUT_RDWR)
                except OSError:pass
    def close(self):
        self.stop=True;self.cut();self.thread.join(timeout=3);self.listener.close()
        for worker in self.workers:worker.join(timeout=3)
        assert not self.thread.is_alive() and not any(w.is_alive() for w in self.workers)

def viewer_pids(gui):
    found=[]
    for p in Path('/proc').iterdir():
        if not p.name.isdigit():continue
        try:
            status=(p/'status').read_text()
            parent=next(line.split()[1] for line in status.splitlines() if line.startswith('PPid:'))
            if int(parent)==gui.pid and b'--viewer\0' in (p/'cmdline').read_bytes():found.append(int(p.name))
        except (OSError,StopIteration):continue
    assert len(found)<=1, 'Overlapping Viewer worker processes'
    return found

def exercise_auto_reconnect(output,agent,start):
    loop=GLib.MainLoop();thread=threading.Thread(target=loop.run,daemon=True);thread.start()
    provider=Providers();proxy=Proxy();keyring=PrivateSecrets(output,start)
    initial=cli({'type':'snapshot'});server=initial['server'];keyring.seed_isolation(server)
    checks=[];gui=None
    try:
        wait(lambda:cli({'type':'snapshot'})['recovery']['network_monitor'],'Private network provider missing')
        for case in ['network','cancel','wrong','missing','nonretry','budget','scope']:
            directory=output/case;directory.mkdir()
            password='incorrect-stored-password' if case=='wrong' else 'native-viewer-smoke'
            if case=='missing':Secret.password_clear_sync(SCHEMA,attributes(server,PEER),None)
            else:assert Secret.password_store_sync(SCHEMA,attributes(server,PEER),Secret.COLLECTION_DEFAULT,'FarPane recovery fixture',password,None)
            proxy.drop_new=False
            env=dict(os.environ,DISPLAY=':92',GSK_RENDERER='cairo',GTK_A11Y='none',FARPANE_VIEWER_SMOKE_DIR=str(directory))
            gui=start('auto-'+case,[str(RELEASE/'farpane')],env)
            def progress():
                assert gui.poll() is None,'GUI exited unexpectedly'
                viewer_pids(gui)
                return read(directory/'auto-progress.json')
            wait(lambda:progress().get('presented'),'Initial video missing',25)
            original=progress();old_worker=viewer_pids(gui);assert len(old_worker)==1
            baseline=len(proxy.records)
            (directory/'auto-enable').touch()
            wait(lambda:progress().get('enabled'),'Actual recovery checkbox did not enable')
            if case=='network':
                provider.network(20,'/')
                wait(lambda:cli({'type':'snapshot'})['recovery']['phase']=='waiting_network','Network pause missing')
            if case=='cancel':keyring.pause()
            if case=='budget':proxy.drop_new=True
            if case=='scope':
                current=cli({'type':'snapshot'})
                cli({'type':'set_server','data':{'settings':dict(server,public_key=server['public_key']+'-changed'),'revision':current['revision']}})
                wait(lambda:not progress().get('enabled',True),'Server scope change did not cancel recovery')
            if case=='nonretry':
                inbound=cli({'type':'snapshot'})['inbound'];assert len(inbound)==1
                cli({'type':'disconnect_inbound','data':{'connection':inbound[0]['id']}})
            else:proxy.cut()
            if case=='network':
                wait(lambda:progress().get('phase') in ('failed','ended'),'Drop did not reach GUI')
                time.sleep(1);assert len(proxy.records)==baseline and progress()['enabled']
                provider.network(70,'/test/restored')
                wait(lambda:progress().get('cycle')==1 and progress().get('presented'),'Saved-password recovery did not present',25)
                assert progress()['session']!=original['session'] and not Path(f'/proc/{old_worker[0]}').exists()
                assert read(directory/'cycle-0.json')['worker_reaped']
                checks+=['network_pause_then_real_saved_password_recovery','old_worker_reaped_same_gui_new_session']
            elif case=='cancel':
                wait(lambda:progress().get('cycle')==1 and progress().get('lookup'),'Pending keyring lookup missing',20)
                (directory/'auto-disable').touch()
                wait(lambda:not progress().get('enabled',True),'Cancel did not disable recovery')
                keyring.resume();time.sleep(1)
                current=progress();assert current['challenge']==1 and not current['presented'] and not current['lookup']
                checks.append('cancel_stalled_keyring_discards_late_password')
            elif case in ('wrong','missing'):
                wait(lambda:progress().get('cycle')==1 and progress().get('challenge')==1 and not progress().get('enabled',True),'Credential failure did not return to user',20)
                time.sleep(1);assert progress()['cycle']==1 and not progress()['presented']
                checks.append(case+'_saved_password_stops_automatic_recovery')
            elif case in ('nonretry','scope'):
                wait(lambda:progress().get('phase') in ('failed','ended') and not progress().get('enabled',True),'Nonretryable close not respected',15)
                time.sleep(1);assert len(proxy.records)==baseline and progress()['cycle']==0
                checks.append(case+'_does_not_reconnect')
            else:
                wait(lambda:progress().get('cycle')==4 and not progress().get('enabled',True),'Four-attempt budget did not exhaust',45)
                time.sleep(1);assert len(proxy.records)==baseline+4
                for cycle in range(4):assert read(directory/f'cycle-{cycle}.json')['worker_reaped']
                checks.append('four_actual_replacement_connections_then_stop')
            (directory/'final-progress.json').write_text(json.dumps(progress(),indent=2)+'\n')
            (directory/'clipboard-complete').touch();assert gui.wait(timeout=15)==0
            assert not viewer_pids(gui) and agent.poll() is None
            if case=='scope':
                current=cli({'type':'snapshot'});cli({'type':'set_server','data':{'settings':server,'revision':current['revision']}})
            wait(lambda:not cli({'type':'snapshot'})['inbound'],'Inbound session did not retire')
        after=cli({'type':'snapshot'})
        for key in ['local_id','authentication','permanent_password_set','host_enabled','sharing','gpu_enabled','server']:
            assert initial[key]==after[key],key
        for base in [Path(os.environ['XDG_CONFIG_HOME']),Path(os.environ['XDG_DATA_HOME'])]:
            for p in base.rglob('*.toml'):assert b'native-viewer-smoke' not in p.read_bytes()
        result={'result':'pass','checks':checks,'gui_rounds':7,'gpu':False,'network':'private loopback proxy',
                'credentials':'private keyring with synthetic passwords','host_process_preserved':True}
        (output/'auto-reconnect-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True)
    finally:
        keyring.resume()
        if gui is not None and gui.poll() is None:gui.terminate();gui.wait(timeout=8)
        (output/'proxy-connections.json').write_text(json.dumps(proxy.records,indent=2)+'\n')
        (output/'auto-reconnect-checks.json').write_text(json.dumps(checks,indent=2)+'\n')
        proxy.close();provider.c.close_sync(None);loop.quit();thread.join(timeout=2)
