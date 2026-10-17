"""Private system-bus events + actual UDP registration and live video; no host changes."""
import json,os,socket,threading,time
from gi.repository import Gio,GLib
from native_host_smoke import cli,RELEASE
from native_desktop_smoke import connection,call,wait,read

LOGIN='org.freedesktop.login1'
LOGIN_IFACE=LOGIN+'.Manager'
LOGIN_PATH='/org/freedesktop/login1'
NETWORK='org.freedesktop.NetworkManager'
NETWORK_PATH='/org/freedesktop/NetworkManager'

class Providers:
    def __init__(self):
        self.c=connection();self.sleeping=False;self.state=70;self.primary='/test/one'
        xml=f'''<node><interface name="{LOGIN_IFACE}">
        <property name="PreparingForSleep" type="b" access="read"/>
        <signal name="PrepareForSleep"><arg type="b"/></signal></interface></node>'''
        self.c.register_object(LOGIN_PATH,Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0],None,self.property,None)
        xml=f'''<node><interface name="{NETWORK}">
        <property name="State" type="u" access="read"/>
        <property name="PrimaryConnection" type="o" access="read"/></interface></node>'''
        self.c.register_object(NETWORK_PATH,Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0],None,self.property,None)
        for name in [LOGIN,NETWORK]:
            assert call(self.c,'org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','RequestName','(su)',(name,4))[0]==1
    def property(self,c,sender,path,interface,name):
        return {'PreparingForSleep':GLib.Variant('b',self.sleeping),'State':GLib.Variant('u',self.state),'PrimaryConnection':GLib.Variant('o',self.primary)}[name]
    def sleep(self,value):
        self.sleeping=value
        self.c.emit_signal(None,LOGIN_PATH,LOGIN_IFACE,'PrepareForSleep',GLib.Variant('(b)',(value,)))
        self.c.flush_sync(None)
    def network(self,state,path):
        self.state=state;self.primary=path
        self.c.emit_signal(None,NETWORK_PATH,'org.freedesktop.DBus.Properties','PropertiesChanged',
            GLib.Variant('(sa{sv}as)',(NETWORK,{'State':GLib.Variant('u',state),'PrimaryConnection':GLib.Variant('o',path)},[])))
        self.c.flush_sync(None)
    def release(self):
        for name in [LOGIN,NETWORK]:call(self.c,'org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','ReleaseName','(s)',(name,))

class Rendezvous:
    def __init__(self):
        self.socket=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        self.socket.bind(('127.0.0.1',21116));self.socket.settimeout(.2)
        self.stop=False;self.respond=True;self.packets=[]
        self.thread=threading.Thread(target=self.run,daemon=True);self.thread.start()
    def run(self):
        while not self.stop:
            try:body,peer=self.socket.recvfrom(65536)
            except socket.timeout:continue
            # Fixed pinned rendezvous.proto: peer=6/response=7, pk=15/response=16.
            # Only packet kind/time/source port are retained, never IDs/keys.
            if body[:1] not in (b'\x32',b'\x7a'):continue
            self.packets.append({'kind':'peer' if body[0]==0x32 else 'pk','port':peer[1],'at':time.monotonic()})
            if self.respond:
                if self.respond=='reject':
                    answer=b'\x3a\x02\x10\x01' if body[0]==0x32 else b'\x82\x01\x02\x08\x07'
                else:answer=b'\x3a\x00' if body[0]==0x32 else b'\x82\x01\x00'
                self.socket.sendto(answer,peer)
    def ports(self):return {p['port'] for p in self.packets}
    def close(self):self.stop=True;self.thread.join(timeout=2);self.socket.close()

def state():return cli({'type':'snapshot'})

def exercise_recovery(output,agent,start):
    assert os.environ['DBUS_SYSTEM_BUS_ADDRESS']==os.environ['DBUS_SESSION_BUS_ADDRESS']
    loop=GLib.MainLoop();thread=threading.Thread(target=loop.run,daemon=True);thread.start()
    provider=Providers();providers=[provider];server=Rendezvous();checks=[];gui=None
    history=[]
    def recovery():
        current=state();sample={'registered':current['registered'],'recovery':current['recovery']}
        if not history or history[-1]!=sample:
            history.append(sample)
            del history[:-128]
        return current['recovery']
    initial=state();settings=dict(initial['server'],rendezvous='127.0.0.1:21116',relay='127.0.0.1:21117',public_key='',force_relay=False)
    try:
        cli({'type':'set_server','data':{'settings':settings,'revision':initial['revision']}})
        wait(lambda:recovery()['sleep_monitor'] and recovery()['network_monitor'],'System providers not discovered')
        wait(lambda:state()['registered'],'Actual UDP registration did not receive acknowledgement',20)
        initial=state();assert recovery()['epoch']==0
        checks.append('initial_typed_properties_and_actual_registration')
        # Render the home state while the fixture reports an offline network.
        provider.network(20,'/')
        wait(lambda:recovery()['phase']=='waiting_network','Network offline not reported')
        home=output/'home';home.mkdir()
        env=dict(os.environ,DISPLAY=':92',GSK_RENDERER='cairo',GTK_A11Y='none',FARPANE_DESKTOP_SMOKE_DIR=str(home),FARPANE_SMOKE_REPORT_DIR=str(home))
        gui=start('recovery-home',[str(RELEASE/'farpane')],env)
        wait(lambda:read(home/'desktop-progress.json').get('recovery_label')=='等待网络恢复','Actual home label missing')
        wait(lambda:(home/'page-0.png').exists(),'Home not rendered')
        (home/'close-window').touch();assert gui.wait(timeout=12)==0
        checks.append('actual_gui_reports_network_recovery_state')
        provider.network(50,'/test/two')
        wait(lambda:recovery()['phase']=='ready' and recovery()['attempt']==1,'Local-only network did not restore registration',15)
        checks.append('local_network_ready_without_internet_requirement')
        directory=output/'live';directory.mkdir()
        env=dict(os.environ,DISPLAY=':92',GSK_RENDERER='cairo',GTK_A11Y='none',FARPANE_VIEWER_SMOKE_DIR=str(directory),FARPANE_DESKTOP_SMOKE_DIR=str(directory))
        gui=start('recovery-viewer',[str(RELEASE/'farpane')],env)
        wait(lambda:(directory/'viewer-window.png').exists(),'Actual Viewer did not present',25)
        before=state();inbound=[c['id'] for c in before['inbound']];assert inbound
        # Directed signals also test local sender validation, bypassing the bus's broadcast match.
        spoof=connection();names=call(spoof,'org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','ListNames')[0]
        epoch=recovery()['epoch']
        for name in names:
            if not name.startswith(':'):continue
            pid=call(spoof,'org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','GetConnectionUnixProcessID','(s)',(name,))[0]
            if pid==agent.pid:
                for sleeping in [True,False]:spoof.emit_signal(name,LOGIN_PATH,LOGIN_IFACE,'PrepareForSleep',GLib.Variant('(b)',(sleeping,)))
        spoof.flush_sync(None);time.sleep(.8);spoof.close_sync(None)
        assert recovery()['epoch']==epoch and recovery()['phase']=='ready'
        checks.append('untrusted_directed_system_signals_ignored')
        ports=server.ports();provider.sleep(True)
        wait(lambda:recovery()['phase']=='suspended','PrepareForSleep(true) not observed')
        provider.sleep(False)
        wait(lambda:recovery()['epoch']>epoch and recovery()['phase']=='ready','Wake registration not confirmed',15)
        assert server.ports()-ports,'No newly bound registration socket'
        assert agent.poll() is None and [c['id'] for c in state()['inbound']]==inbound and gui.poll() is None
        checks.append('wake_reregisters_without_restarting_live_host_or_viewer')
        epoch=recovery()['epoch'];ports=server.ports()
        provider.network(20,'/')
        wait(lambda:recovery()['phase']=='waiting_network','Offline transition missing')
        provider.network(70,'/test/three')
        wait(lambda:recovery()['epoch']>epoch and recovery()['phase']=='ready','Network recovery not confirmed',15)
        assert server.ports()-ports and [c['id'] for c in state()['inbound']]==inbound
        epoch=recovery()['epoch']
        for _ in range(12):provider.network(70,'/test/three')
        time.sleep(1);assert recovery()['epoch']==epoch
        checks+=['network_change_preserves_live_authorized_session','duplicate_network_signals_do_not_restart_registration']
        frames_before=read(directory/'viewer-progress.json').get('frames',0)
        start('recovery-new-frame',['xmessage','-display',':91','-geometry','300x100+10+10','Restored registration, same media session'])
        wait(lambda:read(directory/'viewer-progress.json').get('frames',0)>frames_before,'Video stopped presenting after registration recovery')
        (directory/'clipboard-complete').touch();assert gui.wait(timeout=15)==0
        report=read(directory/'viewer.json');assert report['presented'] and report['worker_reaped'] and report['frames']>frames_before
        checks.append('video_still_presents_and_viewer_reaps_after_events')
        # No acknowledgement: fast recovery must stop after its finite budget.
        server.respond=False;provider.sleep(True);provider.sleep(False)
        wait(lambda:recovery()['phase']=='waiting_server','Fast recovery did not exhaust',28)
        assert recovery()['attempt']==3
        exhausted=recovery()['epoch'];time.sleep(2)
        assert recovery()['epoch']==exhausted and recovery()['attempt']==3
        checks.append('three_attempt_budget_exhausts_without_false_ready')
        # A response with measured latency is not necessarily registration approval.
        epoch=recovery()['epoch'];server.respond='reject';provider.sleep(True);provider.sleep(False)
        wait(lambda:recovery()['epoch']>epoch and recovery()['phase']=='waiting_server','Rejected registration was reported as ready',28)
        assert recovery()['attempt']==3 and not state()['registered']
        rejected=output/'rejected';rejected.mkdir()
        env=dict(os.environ,DISPLAY=':92',GSK_RENDERER='cairo',GTK_A11Y='none',FARPANE_DESKTOP_SMOKE_DIR=str(rejected),FARPANE_SMOKE_REPORT_DIR=str(rejected))
        gui=start('recovery-rejected',[str(RELEASE/'farpane')],env)
        wait(lambda:read(rejected/'desktop-progress.json').get('recovery_label')=='快速恢复未成功，核心继续等待服务器','Rejected registration not shown in actual GUI')
        wait(lambda:(rejected/'page-0.png').exists(),'Rejected state not rendered')
        (rejected/'close-window').touch();assert gui.wait(timeout=12)==0
        checks.append('registration_rejection_never_becomes_ready_from_latency_alone')
        provider.network(20,'/');provider.sleep(True);provider.sleep(False)
        wait(lambda:recovery()['phase']=='waiting_network','Recovery did not pause for network')
        current=state();cli({'type':'set_host','data':{'enabled':False,'revision':current['revision']}})
        provider.network(70,'/test/four')
        wait(lambda:recovery()['phase']=='disabled','Disabled Host accepted a recovery')
        time.sleep(1);assert recovery()['attempt']==0 and not state()['host_enabled']
        checks.append('disabled_host_cancels_pending_recovery')
        current=state();server.respond=True
        cli({'type':'set_host','data':{'enabled':True,'revision':current['revision']}})
        wait(lambda:state()['registered'],'Host did not register when explicitly enabled',20)
        provider.release();replacement=Providers();providers.append(replacement)
        wait(lambda:recovery()['sleep_monitor'] and recovery()['network_monitor'],'Replacement providers missing')
        # Allow owner-change processing before comparing retired sender effects.
        time.sleep(1);epoch=recovery()['epoch']
        provider.sleep(True);provider.sleep(False);time.sleep(1)
        assert recovery()['epoch']==epoch and recovery()['phase']!='suspended'
        replacement.sleep(True)
        wait(lambda:recovery()['phase']=='suspended','New provider was not accepted')
        replacement.sleep(False)
        wait(lambda:recovery()['phase']=='ready','New provider wake did not recover',15)
        checks.append('provider_replacement_rejects_retired_owner')
        after=state()
        for key in ['local_id','authentication','permanent_password_set','temporary_password','sharing','gpu_enabled','server','host_enabled']:
            assert after[key]==initial[key],key
        assert agent.poll() is None
        result={'result':'pass','checks':checks,'host_process_preserved':True,'actual_sleep_or_network_change':False,
                'system_providers':'private D-Bus fixtures','registration':'actual loopback UDP/protobuf','gpu':False}
        (output/'recovery-result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True)
    finally:
        (output/'registration-packets.json').write_text(json.dumps(server.packets,indent=2)+'\n')
        (output/'recovery-history.json').write_text(json.dumps(history,indent=2)+'\n')
        (output/'recovery-checks.json').write_text(json.dumps(checks,indent=2)+'\n')
        if gui is not None and gui.poll() is None:
            gui.terminate();gui.wait(timeout=8)
        for item in providers:item.c.close_sync(None)
        server.close();loop.quit();thread.join(timeout=2)
