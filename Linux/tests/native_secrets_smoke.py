"""Only synthetic credentials on this test container's private session bus."""
import ctypes,hashlib,json,os,signal,subprocess,threading,time
from pathlib import Path
import gi
gi.require_version('Secret','1')
from gi.repository import Gio,GLib,Secret
from native_host_smoke import RUNTIME,RELEASE,cli

SCHEMA=Secret.Schema.new('org.farpane.RemotePassword.v1',Secret.SchemaFlags.NONE,
                       {'peer':Secret.SchemaAttributeType.STRING,'scope':Secret.SchemaAttributeType.STRING})
def attributes(server,peer='127.0.0.1:21118'):
    scope=json.dumps([server['rendezvous'].lower(),server['public_key']],ensure_ascii=False,separators=(',',':'))
    return {'peer':peer,'scope':hashlib.sha256(scope.encode()).hexdigest()}

class PrivateSecrets:
    def __init__(self,output,start):
        assert Path('/.dockerenv').exists() and str(RUNTIME).startswith('/run/farpane-native-test/')
        self.output=output;self.directory=RUNTIME/'keyring-control';self.directory.mkdir(mode=0o700)
        home=RUNTIME/'keyring-home';home.mkdir(mode=0o700)
        env=dict(os.environ,HOME=str(home),DISPLAY=':92',GNOME_KEYRING_CONTROL=str(self.directory))
        self.env=env
        self.process=start('private-keyring',['gnome-keyring-daemon','--foreground','--unlock','--components=secrets','--control-directory',str(self.directory)],env,stdin_bytes=b'synthetic-keyring-unlock')
        deadline=time.monotonic()+8
        bus=Gio.bus_get_sync(Gio.BusType.SESSION,None)
        while True:
            assert self.process.poll() is None,'Private keyring exited'
            owned=bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','NameHasOwner',GLib.Variant('(s)',('org.freedesktop.secrets',)),None,0,1000,None).unpack()[0]
            if owned:break
            assert time.monotonic()<deadline,'Private keyring bus name missing';time.sleep(.05)
        self.service=Secret.Service.get_sync(Secret.ServiceFlags.OPEN_SESSION,None)
        self.paused=False
    def lookup(self,server,peer='127.0.0.1:21118'):
        items=self.service.search_sync(SCHEMA,attributes(server,peer),Secret.SearchFlags.ALL|Secret.SearchFlags.LOAD_SECRETS,None)
        assert len(items)<=1,'Duplicate test credentials'
        if not items:return None
        assert not items[0].get_locked(),'Test keyring unexpectedly locked'
        return items[0].get_secret().get_text()
    def seed_isolation(self,server):
        self.server=server;self.other=dict(server,public_key=server['public_key']+'-different-key')
        for target,peer in [(self.other,'127.0.0.1:21118'),(server,'independent-device')]:
            assert Secret.password_store_sync(SCHEMA,attributes(target,peer),Secret.COLLECTION_DEFAULT,'FarPane isolation fixture','unrelated-synthetic-secret',None)
    def seed_password(self,password='native-viewer-smoke'):
        assert Secret.password_store_sync(SCHEMA,attributes(self.server),Secret.COLLECTION_DEFAULT,'FarPane synthetic login',password,None)
    def pause(self):
        assert self.process.poll() is None
        self.process.send_signal(signal.SIGSTOP);self.paused=True
    def resume(self):
        if self.paused:self.process.send_signal(signal.SIGCONT);self.paused=False
    def verify(self,saved=True):
        assert self.lookup(self.server)==('native-viewer-smoke' if saved else None)
        assert self.lookup(self.other)=='unrelated-synthetic-secret'
        assert self.lookup(self.server,'independent-device')=='unrelated-synthetic-secret'
        keyrings=list((Path(os.environ['XDG_DATA_HOME'])/'keyrings').glob('*.keyring'))
        assert keyrings,'No persistent encrypted test keyring'
        assert all(b'native-viewer-smoke' not in p.read_bytes() for p in keyrings)
        for base in [Path(os.environ['XDG_CONFIG_HOME']),Path(os.environ['XDG_DATA_HOME'])]:
            for p in base.rglob('*.toml'):assert b'native-viewer-smoke' not in p.read_bytes(),'Secret copied into ordinary config'
    def report(self):
        self.verify(False)
        (self.output/'secrets-result.json').write_text(json.dumps({'result':'pass','wrong-password-not-stored':True,'authenticated-password-stored':True,'second-gui-loads-saved-password':True,'cancel-stalled-keyring-keeps-video-login':True,'delete-confirmed':True,'server-public-key-and-peer-isolation':True,'no-plaintext-config-fallback':True,'keyring_pid':self.process.pid},indent=2))
    def sample(self,directory):
        raw=Path(f'/proc/{self.process.pid}/smaps_rollup').read_text()
        (directory/'keyring-smaps-rollup.txt').write_text(raw)
        values={line.split(':')[0]:int(line.split()[1]) for line in raw.splitlines()[1:] if ':' in line}
        path=directory/'process-sample.json';report=json.loads(path.read_text())
        report['processes']['private-keyring']={'pid':self.process.pid,'pss_kib':values['Pss'],'rss_kib':values['Rss']}
        path.write_text(json.dumps(report,indent=2))
    def device_ui(self,start):
        self.verify(False);self.seed_password();self.verify(True)
        state=cli({'type':'snapshot'});assert len(state['devices'])==1
        directory=self.output/'devices-secrets';directory.mkdir()
        process=start('devices-secrets',[str(RELEASE/'farpane')],dict(os.environ,DISPLAY=':92',GSK_RENDERER='cairo',GTK_A11Y='none',FARPANE_DEVICES_SECRET_DIR=str(directory)))
        deadline=time.monotonic()+35
        while process.poll() is None and time.monotonic()<deadline:
            if (directory/'delete-cancelled').exists() and not (directory/'cancel-verified').exists():
                self.verify(True);(directory/'cancel-verified').touch()
            if (directory/'delete-requested').exists() and not (directory/'delete-verified').exists() and self.lookup(self.server) is None:
                self.verify(False)
                assert cli({'type':'snapshot'})['devices']==state['devices']
                (directory/'delete-verified').touch()
            if (directory/'ready-to-reseed').exists() and not (directory/'reseeded').exists():
                self.seed_password();self.verify(True);(directory/'reseeded').touch()
            time.sleep(.05)
        assert process.poll()==0,'Device credential GUI did not complete'
        report=json.loads((directory/'devices-secrets.json').read_text());assert report['result']=='pass',report
        self.verify(False)
        after=cli({'type':'snapshot'})
        assert after['devices']==[] and after['revision']==state['revision']+1
        assert after['local_id']==state['local_id']
        assert 'CRITICAL' not in (self.output/'devices-secrets.log').read_text()
    def bridge_checks(self):
        # Exercise the canonical C boundary against the real private provider.
        # No synthetic password is passed on argv or recorded in the evidence.
        # Runtime is deliberately noexec; generated test artifacts belong in Build.
        library=self.output/'secret-bridge-test.so'
        flags=subprocess.check_output(['pkg-config','--cflags','libsecret-1'],text=True).split()
        links=subprocess.check_output(['pkg-config','--libs','gio-2.0'],text=True).split()
        subprocess.run(['cc','-shared','-fPIC','-Wall','-Wextra','-Werror',
                        '/workspace/Linux/gui/src/secret_service.c','-o',str(library),*flags,*links,'-ldl'],check=True)
        bridge=ctypes.CDLL(str(library));gio=ctypes.CDLL('libgio-2.0.so.0')
        gio.g_cancellable_new.restype=ctypes.c_void_p
        gio.g_cancellable_cancel.argtypes=[ctypes.c_void_p]
        gio.g_object_unref.argtypes=[ctypes.c_void_p]
        bridge.farpane_secret_execute.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_char_p,ctypes.c_void_p,ctypes.POINTER(ctypes.c_void_p)]
        bridge.farpane_secret_free.argtypes=[ctypes.c_void_p]
        attrs=attributes(self.server)
        def execute(action,cancel_after=None):
            cancel=gio.g_cancellable_new();out=ctypes.c_void_p();timer=None
            if cancel_after is not None:
                timer=threading.Timer(cancel_after,lambda:gio.g_cancellable_cancel(cancel));timer.start()
            try:
                status=bridge.farpane_secret_execute(action,attrs['peer'].encode(),attrs['scope'].encode(),b'must-not-replace-locked-value' if action==1 else None,cancel,ctypes.byref(out))
                assert not out.value,'Negative/delete operation unexpectedly returned a password'
                return status
            finally:
                if timer:timer.cancel();timer.join()
                if out.value:bridge.farpane_secret_free(out)
                gio.g_object_unref(cancel)
        self.seed_password('x'*4097)
        assert execute(0)==6,'Oversized SecretValue was accepted'
        assert execute(2)==0
        self.seed_password()
        collection=Secret.Collection.for_alias_sync(self.service,Secret.COLLECTION_DEFAULT,Secret.CollectionFlags.NONE,None)
        bus=Gio.bus_get_sync(Gio.BusType.SESSION,None)
        path=collection.get_object_path()
        self.locked_collection=path
        bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','UpdateActivationEnvironment',GLib.Variant('(a{ss})',({'DISPLAY':':92','GTK_A11Y':'none'},)),None,0,5000,None)
        bus.call_sync('org.freedesktop.secrets','/org/freedesktop/secrets','org.freedesktop.Secret.Service','Lock',GLib.Variant('(ao)',([path],)),None,0,5000,None)
        def locked():
            return bus.call_sync('org.freedesktop.secrets',path,'org.freedesktop.DBus.Properties','Get',GLib.Variant('(ss)',('org.freedesktop.Secret.Collection','Locked')),None,0,5000,None).unpack()[0]
        assert locked(),'Private keyring did not lock'
        statuses={name:execute(action,1.0) for name,action in [('locked_lookup',0),('locked_delete',2),('locked_store',1)]}
        assert all(code==2 for code in statuses.values()),statuses
        assert locked(),'Refused operation unlocked the keyring'
        items=self.service.search_sync(SCHEMA,attrs,Secret.SearchFlags.ALL,None)
        assert len(items)==1,'Cancelled locked deletion removed the credential'
        assert self.process.poll() is None,'Private keyring exited after refusing locked operations'
        (self.output/'secret-bridge-result.json').write_text(json.dumps({'result':'pass','oversized-value-rejected':True,'unlocked-deletion':True,'locked-operations-keep-record':True,'locked-statuses':statuses,'provider-alive':True,'manual-system-unlock-tested':False},indent=2))
    def verify_locked(self):
        assert self.process.poll() is None,'Locked provider exited during GUI lookup'
        bus=Gio.bus_get_sync(Gio.BusType.SESSION,None)
        locked=bus.call_sync('org.freedesktop.secrets',self.locked_collection,'org.freedesktop.DBus.Properties','Get',GLib.Variant('(ss)',('org.freedesktop.Secret.Collection','Locked')),None,0,5000,None).unpack()[0]
        assert locked,'GUI unlocked the keyring'
        owned=bus.call_sync('org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','NameHasOwner',GLib.Variant('(s)',('org.gnome.keyring.SystemPrompter',)),None,0,5000,None).unpack()[0]
        assert not owned,'GUI invoked a system Unlock prompt'
        items=self.service.search_sync(SCHEMA,attributes(self.server),Secret.SearchFlags.ALL,None)
        assert len(items)==1,'GUI removed the locked record'
