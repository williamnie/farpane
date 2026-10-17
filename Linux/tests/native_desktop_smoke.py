"""Private session D-Bus fixtures against the real Host, GTK GUI and Viewer."""
import json,os,re,subprocess,threading,time
from pathlib import Path
from gi.repository import Gio,GLib
from native_host_smoke import cli,RELEASE

GUI='org.farpane.FarPane';AGENT=GUI+'.Agent';NOTIFY='org.freedesktop.Notifications';WATCH='org.kde.StatusNotifierWatcher'

def connection():
    return Gio.DBusConnection.new_for_address_sync(os.environ['DBUS_SESSION_BUS_ADDRESS'],Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT|Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,None,None)

def call(c,name,path,interface,method,signature='()',args=(),timeout=5000):
    return c.call_sync(name,path,interface,method,GLib.Variant(signature,args),None,Gio.DBusCallFlags.NONE,timeout,None).unpack()

def wait(check,message,seconds=10):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        result=check()
        if result:return result
        time.sleep(.1)
    raise AssertionError(message)

def read(path):
    try:return json.loads(path.read_text())
    except (FileNotFoundError,json.JSONDecodeError):return {}

def owned(c,name):return call(c,'org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','NameHasOwner','(s)',(name,))[0]

WATCH_XML='''<node><interface name="org.kde.StatusNotifierWatcher">
<method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
<property name="RegisteredStatusNotifierItems" type="as" access="read"/>
<property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
<property name="ProtocolVersion" type="i" access="read"/>
</interface></node>'''
NOTIFY_XML='''<node><interface name="org.freedesktop.Notifications">
<method name="GetCapabilities"><arg type="as" direction="out"/></method>
<method name="GetServerInformation"><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/></method>
<method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/></method>
<method name="CloseNotification"><arg type="u" direction="in"/></method>
<signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
<signal name="ActivationToken"><arg type="u"/><arg type="s"/></signal>
<signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
</interface></node>'''

class Services:
    def __init__(self,output,serial,actions=True,watch=WATCH):
        self.c=connection();self.serial=serial;self.actions=actions;self.output=output;self.watch=watch
        self.registrations=[];self.notifications=[];self.closed=[];self.errors=[]
        self.c.register_object('/StatusNotifierWatcher',Gio.DBusNodeInfo.new_for_xml(WATCH_XML.replace(WATCH,self.watch)).interfaces[0],self.method,self.property,None)
        self.c.register_object('/org/freedesktop/Notifications',Gio.DBusNodeInfo.new_for_xml(NOTIFY_XML).interfaces[0],self.method,None,None)
        for name in [self.watch,NOTIFY]:assert call(self.c,'org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','RequestName','(su)',(name,4))[0]==1
    def property(self,c,sender,path,interface,name):
        if name=='RegisteredStatusNotifierItems':return GLib.Variant('as',[r['name'] for r in self.registrations])
        if name=='IsStatusNotifierHostRegistered':return GLib.Variant('b',True)
        return GLib.Variant('i',0)
    def method(self,c,sender,path,interface,name,parameters,invocation):
        args=parameters.unpack()
        try:
            if name=='RegisterStatusNotifierItem':
                self.registrations.append({'sender':sender,'name':args[0]});result=GLib.Variant('()',())
            elif name=='GetCapabilities':result=GLib.Variant('(as)',(['body','body-markup']+(['actions'] if self.actions else []),))
            elif name=='GetServerInformation':result=GLib.Variant('(ssss)',('FarPane private test','FarPane','1','1.3'))
            elif name=='Notify':
                ident=self.serial*100+len(self.notifications)+1
                self.notifications.append({'id':ident,'sender':sender,'arguments':args})
                result=GLib.Variant('(u)',(ident,))
            elif name=='CloseNotification':
                self.closed.append(args[0]);self.emit('NotificationClosed','(uu)',(args[0],3));result=GLib.Variant('()',())
            else:raise AssertionError(name)
            invocation.return_value(result)
        except Exception as e:
            self.errors.append(str(e));invocation.return_dbus_error('org.farpane.Test.Error',str(e))
    def emit(self,name,signature,args):
        self.c.emit_signal(None,'/org/freedesktop/Notifications',NOTIFY,name,GLib.Variant(signature,args));self.c.flush_sync(None)
    def release(self):
        for name in [self.watch,NOTIFY]:call(self.c,'org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','ReleaseName','(s)',(name,))
    def close(self):
        (self.output/f'provider-{self.serial}.json').write_text(json.dumps({'owner':self.c.get_unique_name(),'registrations':self.registrations,'notifications':self.notifications,'closed':self.closed,'errors':self.errors},indent=2))
        self.c.close_sync(None)

def exercise_desktop(output,agent,start):
    state=cli({'type':'snapshot'})
    state=cli({'type':'set_authentication','data':{'mode':'approval','password':None,'revision':state['revision']}})
    loop=GLib.MainLoop();thread=threading.Thread(target=loop.run,daemon=True);thread.start()
    control=connection();services=[];gui_pids=[];checks=[]
    def activate_env(directory):
        call(control,'org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','UpdateActivationEnvironment','(a{ss})',({'DISPLAY':':92','GSK_RENDERER':'cairo','GTK_A11Y':'none','FARPANE_DESKTOP_SMOKE_DIR':str(directory)},))
    def progress(directory):return read(directory/'desktop-progress.json')
    def gone(pid):return not Path(f'/proc/{pid}/exe').exists()
    def stop_gui(directory):
        pid=progress(directory)['pid'];(directory/'close-window').touch()
        wait(lambda:not owned(control,GUI),'GUI did not release its bus name',16)
        wait(lambda:gone(pid),'GUI retained a process after closing',5)
        assert agent.poll() is None
    def sample_gui(directory):
        pid=progress(directory)['pid']
        for source,target in [('smaps_rollup','gui-smaps-rollup.txt'),('maps','gui-maps.txt')]:
            (directory/target).write_text(Path(f'/proc/{pid}/{source}').read_text())
    def sni(method):return call(control,AGENT,'/StatusNotifierItem','org.kde.StatusNotifierItem',method,'(ii)',(0,0))
    def launch_viewer(directory):
        directory.mkdir();env=dict(os.environ,DISPLAY=':92',GSK_RENDERER='cairo',GTK_A11Y='none',FARPANE_VIEWER_SMOKE_DIR=str(directory),FARPANE_DESKTOP_SMOKE_DIR=str(directory))
        # A second private application bus models a separate client; Host/control
        # remain in this one container and only synthetic X displays are used.
        return start('viewer-'+directory.name,['dbus-run-session','--',str(RELEASE/'farpane')],env)
    try:
        before=wait(lambda:cli({'type':'snapshot'})['desktop']['connected'],'Host session bus unavailable')
        assert not owned(control,GUI),'GUI was launched without interaction'
        idle=cli({'type':'snapshot'})['desktop'];assert not idle['notifications_available'] and not idle['tray_registered']
        services.append(Services(output,1));provider=services[-1]
        wait(lambda:provider.registrations,'Host failed to register tray')
        wait(lambda:cli({'type':'snapshot'})['desktop']['notification_actions'],'Capabilities not reflected')
        props=call(control,AGENT,'/StatusNotifierItem','org.freedesktop.DBus.Properties','GetAll','(s)',('org.kde.StatusNotifierItem',))[0]
        assert props['Id']=='FarPane' and props['IconName']==GUI and props['Menu']=='/MenuBar'
        assert props['IconPixmap'][0][:2]==(32,32) or list(props['IconPixmap'][0][:2])==[32,32]
        assert len(props['IconPixmap'][0][2])==4096 and props['Status']=='Active'
        menu=call(control,AGENT,'/MenuBar','com.canonical.dbusmenu','GetLayout','(iias)',(0,-1,[]))
        assert menu[0]==1 and len(menu[1][2])==2,menu
        (output/'tray-properties.json').write_text(json.dumps({k:v for k,v in props.items() if 'Pixmap' not in k},indent=2))
        (output/'menu.json').write_text(json.dumps(menu,indent=2))
        checks+=['late-provider-registration','argb-tray-icon','typed-dbusmenu']
        home=output/'home';home.mkdir();activate_env(home);sni('Activate')
        first=wait(lambda:progress(home).get('connected') and progress(home),'D-Bus activation did not create GUI')
        gui_pids.append(first['pid']);assert first['main_windows']==1
        tree=subprocess.check_output(['xwininfo','-display',':92','-root','-tree'],text=True)
        match=re.search(r'(0x[0-9a-f]+) "FarPane"',tree);assert match,tree
        identity=subprocess.check_output(['xprop','-display',':92','-id',match[1],'WM_CLASS','_GTK_APPLICATION_ID','_NET_WM_PID'],text=True)
        (home/'window-identity.txt').write_text(identity)
        assert '_GTK_APPLICATION_ID(UTF8_STRING) = "org.farpane.FarPane"' in identity,identity
        assert str(first['pid']) in identity and 'RustDesk' not in identity,identity
        checks.append('x11-application-identity')
        time.sleep(.6);sni('SecondaryActivate')
        wait(lambda:'本机连接与权限' in progress(home).get('dialogs',[]),'Secondary activation did not open controls')
        assert progress(home)['pid']==first['pid']
        (home/'close-dialogs').touch();wait(lambda:not progress(home).get('dialogs'),'Controls did not close')
        time.sleep(.6);sni('ContextMenu')
        wait(lambda:'FarPane' in progress(home).get('dialogs',[]),'Context menu fallback missing')
        (home/'close-dialogs').touch();wait(lambda:not progress(home).get('dialogs'),'Menu did not close')
        time.sleep(.6)
        call(control,AGENT,'/MenuBar','com.canonical.dbusmenu','Event','(isvu)',(2,'clicked',GLib.Variant('i',0),0))
        wait(lambda:'本机连接与权限' in progress(home).get('dialogs',[]),'DBusMenu did not activate controls')
        assert progress(home)['pid']==first['pid'];sample_gui(home);stop_gui(home)
        checks+=['service-auto-activation','single-gui-owner','secondary-activation','context-menu','dbusmenu-event','gui-close-host-retained']
        pending_gui=output/'pending-gui';pending_gui.mkdir();activate_env(pending_gui)
        video=output/'approved-viewer';viewer=launch_viewer(video)
        wait(lambda:provider.notifications,'Incoming connection was not notified')
        notice=provider.notifications[-1];nid=notice['id']
        assert notice['arguments'][0]=='FarPane' and notice['arguments'][6]['desktop-entry']==GUI
        assert notice['arguments'][7]==30000 and 'review' in notice['arguments'][5]
        wait(lambda:cli({'type':'snapshot'})['inbound'],'Pending connection missing')
        assert not owned(control,GUI) and not (video/'viewer-window.png').exists()
        wait(lambda:read(video/'viewer-progress.json').get('authentication_visible') is False,'Stale password prompt during manual approval')
        assert read(video/'viewer-progress.json')['challenge']==0
        # Signals from an unrelated sender and unrecognized IDs must not activate.
        spoof=connection();spoof.emit_signal(None,'/org/freedesktop/Notifications',NOTIFY,'ActionInvoked',GLib.Variant('(us)',(nid,'review')));spoof.flush_sync(None)
        provider.emit('ActionInvoked','(us)',(nid+999,'review'));time.sleep(.8)
        assert not owned(control,GUI),'Untrusted notification action activated GUI';spoof.close_sync(None)
        # Replace both desktop services while the request is still pending.
        provider.release();services.append(Services(output,2));replacement=services[-1]
        wait(lambda:replacement.registrations and replacement.notifications,'Service restart was not recovered')
        provider.emit('ActionInvoked','(us)',(nid,'review'));time.sleep(.7)
        assert not owned(control,GUI),'Retired notification owner activated GUI'
        nid2=replacement.notifications[-1]['id']
        replacement.emit('ActivationToken','(us)',(nid2,'farpane-private-test-token'))
        replacement.emit('ActionInvoked','(us)',(nid2,'review'))
        opened=wait(lambda:'本机连接与权限' in progress(pending_gui).get('dialogs',[]) and progress(pending_gui),'Notification action did not open controls')
        gui_pids.append(opened['pid']);assert opened['pid']!=first['pid']
        assert not (video/'viewer-window.png').exists() and not cli({'type':'snapshot'})['inbound'][0]['authorized']
        wait(lambda:(pending_gui/'connections.png').exists(),'Connection dialog did not render')
        sample_gui(pending_gui)
        (pending_gui/'approve').touch()
        wait(lambda:(video/'viewer-window.png').exists(),'Actual approval did not present video')
        assert read(video/'viewer-progress.json')['authentication_visible'] is False, 'Password form covers authenticated video'
        wait(lambda:nid2 in replacement.closed,'Accepted notification was not closed')
        viewer.wait(timeout=15);assert viewer.returncode==0
        report=read(video/'viewer.json');assert report['presented'] and report['worker_reaped'] and report['password_attempts']==0,report
        assert report['authentication_visible'] is False and report['challenge']==0
        wait(lambda:not cli({'type':'snapshot'})['inbound'],'Session did not end')
        stop_gui(pending_gui)
        replacement.emit('ActionInvoked','(us)',(nid2,'review'));time.sleep(.7);assert not owned(control,GUI)
        checks+=['closed-gui-inbound-notice','sender-and-id-filter','provider-restart-recovery','retired-owner-ignored','notification-opens-controls-only','actual-approval-presents-video','no-stale-password-prompt','notice-closed-on-authorize','stale-action-ignored']
        replacement.release();services.append(Services(output,3,actions=False,watch="org.freedesktop.StatusNotifierWatcher"));plain=services[-1]
        wait(lambda:plain.registrations and not cli({'type':'snapshot'})['desktop']['notification_actions'],'No-actions capability not reflected')
        video=output/'timeout-viewer';viewer=launch_viewer(video)
        wait(lambda:plain.notifications,'Plain notification missing')
        assert plain.notifications[-1]['arguments'][5]==[], 'Actions sent to an unsupported provider'
        plain.emit('ActionInvoked','(us)',(plain.notifications[-1]['id'],'review'));time.sleep(.7)
        assert not owned(control,GUI),'Action accepted despite missing capability'
        wait(lambda:cli({'type':'snapshot'})['inbound'],'Missing unanswered request')
        plain.release()
        wait(lambda:not cli({'type':'snapshot'})['desktop']['notifications_available'],'Provider disappearance not reflected')
        began=time.monotonic();report=wait(lambda:read(video/'viewer.json'),'Unanswered Viewer worker did not exit',42)
        elapsed=time.monotonic()-began
        assert viewer.poll() is None,'GUI should retain the failed page for retry'
        (video/'close-window').touch();viewer.wait(timeout=15);assert viewer.returncode==0
        assert not report['presented'] and report['frames']==0 and report['worker_reaped'],report
        assert elapsed>24,'Approval timeout was shortened'
        assert not owned(control,GUI) and not cli({'type':'snapshot'})['inbound']
        after=cli({'type':'snapshot'});assert agent.poll() is None
        for key in ['local_id','host_enabled','authentication','permanent_password_set','server','sharing','gpu_enabled']:
            assert after[key]==state[key],key
        maps=Path(f'/proc/{agent.pid}/maps').read_text();assert 'libgtk' not in maps and 'libadwaita' not in maps
        (output/'host-maps.txt').write_text(maps)
        (output/'host-smaps-rollup.txt').write_text(Path(f'/proc/{agent.pid}/smaps_rollup').read_text())
        checks+=['freedesktop-watcher-fallback','notification-without-actions','provider-disappearance','unanswered-timeout-no-frames','no-retained-host-gui','host-no-toolkit','identity-policy-preserved']
        assert all(not service.errors for service in services)
        result={'result':'pass','checks':checks,'gui_pids':gui_pids,'host_pid':agent.pid,'desktop':after['desktop'],'timeout_after_provider_loss_seconds':elapsed}
        (output/'desktop-result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
    finally:
        for service in services:service.close()
        control.close_sync(None);loop.quit();thread.join(timeout=2)
