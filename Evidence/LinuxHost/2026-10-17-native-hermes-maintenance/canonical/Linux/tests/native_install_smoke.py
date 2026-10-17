"""Private container installation transactions with real pidfds and fixture ELFs.

The service controller is a fixture, not systemd/logind acceptance. Never run
against the host: the launcher supplies an isolated /opt and PID namespace.
"""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Linux/packaging'))
import native_bundle
from native_install import Store, atomic_file, link, regular_bytes
from native_install_runtime import Coordinator, Process, Systemd, scan, stop_users

spec=importlib.util.spec_from_file_location('legacy',ROOT/'Scripts/linux/install-app.py')
legacy=importlib.util.module_from_spec(spec);spec.loader.exec_module(legacy)
FIXTURE=Path('/opt/native-install-tests/process-fixture')


class PowerLoss(BaseException):
    pass


def launch(executable,*args,uid=0,ignore=False):
    command=[str(executable),*args]
    if uid:command=['setpriv','--reuid='+str(uid),'--regid='+str(uid),'--clear-groups',*command]
    env={'PATH':'/usr/bin:/bin'}
    if ignore:env['FARPANE_TEST_IGNORE_TERM']='1'
    process=subprocess.Popen(command,env=env,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    deadline=time.monotonic()+3
    while time.monotonic()<deadline:
        if process.poll() is not None:raise AssertionError('Fixture exited prematurely')
        try:
            if (Path('/proc')/str(process.pid)/'exe').readlink()==executable:
                time.sleep(.02);return process
        except FileNotFoundError:pass
        time.sleep(.01)
    raise AssertionError('Fixture did not exec')


class ServiceFixture:
    def __init__(self,store):
        self.store=store;self.process=None;self.events=[];self.fail_next=False

    def snapshot(self,allowed):
        active=self.process is not None and self.process.poll() is None
        if active:
            verified=Process(self.process.pid,allowed)
            try:assert verified.role=='service'
            finally:verified.close()
        return {'active':active,'loaded':(self.store.units/'farpane.service').exists(),'enabled':False}

    def stop(self,allowed):
        if self.snapshot(allowed)['active']:
            self.events.append('service-stop')
            self.process.terminate();self.process.wait(timeout=3)

    def reload(self):self.events.append('daemon-reload')

    def start(self):
        self.events.append('service-start')
        if self.fail_next:self.fail_next=False;raise RuntimeError('Injected service startup failure')
        name=self.store.current();manifest=self.store.verify_release(name,legacy.verify)
        assert (self.store.units/'farpane.service').read_bytes()==self.store.expected_unit(name,manifest)
        release=self.store.base/'releases'/name
        assert release.stat().st_mode&0o777==0o755
        executable=release/('libexec/farpane-core' if manifest.get('kind')=='farpane-native' else 'farpane')
        self.process=launch(executable,'--service')

    def healthy(self,allowed,wanted):return self.snapshot(allowed)['active']==wanted


class InstallTransactions(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(dir=FIXTURE.parent)
        self.root=Path(self.temporary.name);self.root.chmod(0o755)
        self.units=self.root/'units';self.units.mkdir(mode=0o755)
        self.store=Store(self.root/'farpane',self.units)
        self.store.initialize()
        self.old='farpane-p1-fixture';release=self.store.base/'releases'/self.old
        release.mkdir(mode=0o755);(release/'lib').mkdir(mode=0o755)
        shutil.copy2(FIXTURE,release/'farpane')
        manifest={'artifact_id':self.old,'stage':'P1','features':['flutter','hwcodec','drm','farpane-linux','linux-gpu-media'],
                  'files':[{'path':'farpane','sha256':native_bundle.digest(release/'farpane')}]}
        (release/'manifest.json').write_text(json.dumps(manifest));(release/'manifest.json').chmod(0o644)
        link(self.store.base/'current','releases/'+self.old)
        link(self.store.base/'farpane','current/farpane');link(self.store.base/'lib','current/lib')
        atomic_file(self.units/'farpane.service',self.store.expected_unit(self.old,manifest))
        self.old_unit=(self.units/'farpane.service').read_bytes()
        self.source=self.root/'source';self.source.mkdir(mode=0o755)
        for name in native_bundle.REQUIRED-{'lib/libdrmtap.so.0'}:
            path=self.source/name;path.parent.mkdir(parents=True,exist_ok=True,mode=0o755)
            path.write_text('fixture content\n');path.chmod(0o644)
        for name in ('farpane','libexec/farpane-core'):shutil.copy2(FIXTURE,self.source/name)
        shutil.copy2(ROOT/'Linux/packaging/farpane-native.service.in',self.source/'systemd/farpane.service')
        (self.source/'systemd/farpane.service').chmod(0o644)
        library=self.source/'lib/libdrmtap.so.0.5.8';library.parent.mkdir(mode=0o755)
        library.write_text('fixture library');library.chmod(0o755)
        (self.source/'lib/libdrmtap.so.0').symlink_to(library.name)
        self.target=native_bundle.seal(self.source)['artifact_id']
        self.service=ServiceFixture(self.store);self.service.start()
        self.runtime=Coordinator(self.store,self.service,legacy.verify)
        self.children=[]
        # Neither component is in the installer tree. Their bytes and liveness
        # must survive every successful switch and every recovery.
        config=self.root/'private-user-config';config.mkdir(mode=0o700)
        for name in ('FarPane.toml','FarPane2.toml','RustDesk.toml'):
            (config/name).write_bytes(os.urandom(128))
        self.config={p:p.read_bytes() for p in config.iterdir()}
        self.other=self.root/'rustdesk';shutil.copy2(FIXTURE,self.other)
        self.unrelated=launch(self.other,'--server',uid=1000);self.children.append(self.unrelated)

    def tearDown(self):
        for path,data in self.config.items():self.assertEqual(path.read_bytes(),data)
        self.assertIsNone(self.unrelated.poll())
        if self.service.process:self.children.append(self.service.process)
        for process in self.children:
            if process.poll() is None:
                process.terminate()
                try:process.wait(timeout=.5)
                except subprocess.TimeoutExpired:
                    # Only harness-owned, deliberately uncooperative fixtures.
                    process.kill();process.wait(timeout=2)
        self.temporary.cleanup()

    def user(self,role='--server',native=False,ignore=False):
        release=self.store.base/'releases'/(self.target if native else self.old)
        executable=release/('libexec/farpane-core' if native and role else 'farpane')
        process=launch(executable,*([role] if role else []),uid=1000,ignore=ignore)
        self.children.append(process);return process

    def stage(self):return self.store.stage(self.source)

    def apply(self,target=None,old=None):
        return self.runtime.apply(target or self.target,expected_current=old or self.old,maintenance=True)

    def assert_old(self):
        self.assertEqual(self.store.current(),self.old)
        self.assertEqual((self.units/'farpane.service').read_bytes(),self.old_unit)
        self.assertTrue(self.service.snapshot(self.runtime.allowed(self.old))['active'])
        self.assertFalse(self.store.journal.exists())
        self.assertEqual((self.store.base/'releases'/self.old).stat().st_mode&0o777,0o755)

    def test_stage_is_private_and_has_no_runtime_effect(self):
        user=self.user();pid=self.service.process.pid
        self.stage();self.stage()
        self.assertEqual(pid,self.service.process.pid);self.assertIsNone(user.poll());self.assert_old()
        staged=self.store.base/'.staged'/self.target
        self.assertEqual(subprocess.run(['setpriv','--reuid=1000','--regid=1000','--clear-groups','test','-x',str(staged/'farpane')]).returncode,1)
        for path in staged.rglob('*'):self.assertEqual(path.lstat().st_uid,0)

    def test_upgrade_and_explicit_legacy_rollback(self):
        user=self.user();gui=self.user('');self.stage()
        result=self.apply()
        self.assertFalse(result['runtime_ready']);self.assertEqual(result['previous'],self.old)
        self.assertEqual(user.wait(timeout=2),-signal.SIGTERM);self.assertEqual(gui.wait(timeout=2),-signal.SIGTERM)
        self.assertEqual(self.service.events[-3:],['service-stop','daemon-reload','service-start'])
        self.assertEqual((self.store.base/'releases'/self.old).stat().st_mode&0o777,0o700)
        native_user=self.user(native=True);native_gui=self.user('',native=True)
        self.apply(target=self.old,old=self.target);self.assert_old()
        self.assertEqual(native_user.wait(timeout=2),-signal.SIGTERM);self.assertEqual(native_gui.wait(timeout=2),-signal.SIGTERM)
        self.assertEqual((self.store.base/'releases'/self.target).stat().st_mode&0o777,0o700)

    def test_startup_failure_restores_old_service(self):
        self.stage();self.service.fail_next=True
        with self.assertRaisesRegex(RuntimeError,'previous release restored'):self.apply()
        self.assert_old()

    def test_crash_at_every_durable_phase(self):
        self.stage()
        for phase in ('prepared','fenced','switched','starting','committed'):
            with self.subTest(phase=phase):
                write=self.store.write_journal
                def interrupt(record):
                    write(record)
                    if record['phase']==phase:raise PowerLoss(phase)
                with patch.object(self.store,'write_journal',interrupt):
                    with self.assertRaises(PowerLoss):self.apply()
                self.assertEqual(self.store.read_journal()['phase'],phase)
                recovery=self.runtime.recover(maintenance=True)
                if phase=='committed':
                    self.assertEqual(recovery['recovered'],'completed_commit')
                    self.apply(target=self.old,old=self.target)
                self.assert_old()

    def test_crash_between_stage_permission_and_rename(self):
        self.stage();rename=Path.rename
        def interrupt(path,destination):
            if path==self.store.base/'.staged'/self.target:raise PowerLoss('rename')
            return rename(path,destination)
        with patch.object(Path,'rename',interrupt):
            with self.assertRaises(PowerLoss):self.apply()
        self.assertEqual((self.store.base/'.staged'/self.target).stat().st_mode&0o777,0o700)
        self.runtime.recover(maintenance=True);self.assert_old()

    def test_crash_during_unit_write_and_current_switch(self):
        self.stage();import native_install
        actual_link=native_install.link
        def interrupt(path,target):
            if path==self.store.base/'current':raise PowerLoss('unit installed, current old')
            actual_link(path,target)
        with patch.object(native_install,'link',interrupt):
            with self.assertRaises(PowerLoss):self.apply()
        self.runtime.recover(maintenance=True);self.assert_old()

    def test_unknown_role_and_expected_current_fail_without_stopping(self):
        unknown=self.user('--unexpected-role');self.stage();pid=self.service.process.pid
        with self.assertRaisesRegex(ValueError,'Unrecognized role'):self.apply()
        self.assertEqual(pid,self.service.process.pid);self.assertIsNone(unknown.poll());self.assert_old()
        unknown.terminate();unknown.wait(timeout=2)
        with self.assertRaisesRegex(ValueError,'differs from requested'):self.apply(old='farpane-wrong')
        self.assertEqual(pid,self.service.process.pid);self.assert_old()

    def test_missing_authorization_and_concurrent_lock(self):
        self.stage();pid=self.service.process.pid
        with self.assertRaisesRegex(ValueError,'maintenance window'):
            self.runtime.apply(self.target,expected_current=self.old)
        with self.store.locked():
            with self.assertRaises(BlockingIOError):self.apply()
        self.assertEqual(pid,self.service.process.pid);self.assert_old()

    def test_recovery_rejects_modified_unit(self):
        self.stage()
        with self.store.locked():self.store.begin(self.target,expected_current=self.old,service_snapshot=self.service.snapshot(self.runtime.allowed(self.old)),legacy_verify=legacy.verify)
        unit=self.units/'farpane.service';unit.write_bytes(self.old_unit+b'# administrator edit\n')
        with self.assertRaisesRegex(ValueError,'changed outside'):self.runtime.recover(maintenance=True)
        self.assertTrue(unit.read_bytes().endswith(b'# administrator edit\n'))
        self.assertTrue(self.store.journal.exists())
        unit.write_bytes(self.old_unit);self.runtime.recover(maintenance=True);self.assert_old()

    def test_uncooperative_user_is_not_killed(self):
        user=self.user(ignore=True);self.stage()
        self.service.stop(self.runtime.allowed(self.old))
        with self.assertRaisesRegex(TimeoutError,'no SIGKILL'):stop_users(self.runtime.allowed(self.old),timeout=.15)
        self.assertIsNone(user.poll());self.assertEqual(self.store.current(),self.old)

    def test_tampered_copy_and_symlinks_are_rejected(self):
        binary=self.source/'farpane';binary.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError,'type/size changed'):self.stage()
        self.assert_old();self.assertEqual(list((self.store.base/'.staged').iterdir()),[])
        alias=self.root/'source-link';alias.symlink_to(self.source)
        with self.assertRaises(OSError):self.store.stage(alias)
        self.assert_old()

    def test_process_identity_rejects_gui_service_and_deleted_executable(self):
        self.stage();self.apply()
        gui=self.store.base/'releases'/self.target/'farpane'
        process=launch(gui,'--service');self.children.append(process)
        with self.assertRaisesRegex(ValueError,'Unexpected root role'):Process(process.pid,{gui:'gui'})
        process.terminate();process.wait(timeout=2)
        user=self.user('',native=True);gui.unlink()
        with self.assertRaisesRegex(ValueError,'deleted'):scan({gui:'gui',gui.parent/'libexec/farpane-core':'native'})
        self.assertIsNone(user.poll())

    def test_systemd_parser_real_main_pid_and_override_refusal(self):
        allowed=self.runtime.allowed(self.old)
        output='\n'.join(['LoadState=loaded','ActiveState=active','MainPID='+str(self.service.process.pid),
            'FragmentPath='+str(self.units/'farpane.service'),'DropInPaths=',
            'ExecStart={ path='+str(self.store.base/'farpane')+' ; argv[]='+str(self.store.base/'farpane')+' --service ; ignore_errors=no ; }',
            'UnitFileState=disabled','Names=farpane.service'])
        service=Systemd(self.store)
        with patch.object(service,'command',return_value=output):self.assertTrue(service.snapshot(allowed)['active'])
        for bad in (output.replace('DropInPaths=','DropInPaths=/unmanaged.conf'),
                    output.replace('Names=farpane.service','Names=farpane.service rustdesk.service'),
                    output.replace(' --service ;',' --server ;')):
            with patch.object(service,'command',return_value=bad):
                with self.assertRaises(ValueError):service.snapshot(allowed)

    def test_systemd_missing_unit_differs_from_manager_failure(self):
        service=Systemd(self.store)
        missing='LoadState=not-found\nActiveState=inactive\nMainPID=0\n'
        with patch('native_install_runtime.subprocess.run',return_value=subprocess.CompletedProcess([],4,missing,'')):
            self.assertEqual(service.snapshot({}),{'active':False,'loaded':False,'enabled':False})
        with patch('native_install_runtime.subprocess.run',return_value=subprocess.CompletedProcess([],1,'','Failed to connect to bus')):
            with self.assertRaises(subprocess.CalledProcessError):service.snapshot({})

    def test_first_install_failure_restores_absent_unit_and_links(self):
        self.service.stop(self.runtime.allowed(self.old))
        for name in ('current','farpane','lib'):(self.store.base/name).unlink()
        (self.units/'farpane.service').unlink()
        self.stage();self.service.fail_next=True
        with self.assertRaisesRegex(RuntimeError,'previous release restored'):
            self.runtime.apply(self.target,expected_current=None,maintenance=True,start=True)
        self.assertIsNone(self.store.current());self.assertFalse((self.units/'farpane.service').exists())
        self.assertFalse(self.store.journal.exists())
        for name in ('current','farpane','lib'):self.assertFalse((self.store.base/name).is_symlink())

    def test_stage_from_user_owned_source_normalizes_ownership(self):
        for path in [self.source,*self.source.rglob('*')]:os.chown(path,1000,1000,follow_symlinks=False)
        self.stage();self.apply()
        for path in (self.store.base/'releases'/self.target).rglob('*'):self.assertEqual(path.lstat().st_uid,0)

    def test_stale_third_generation_is_refused_without_stopping(self):
        previous=self.store.base/'releases/farpane-old-generation';previous.mkdir(mode=0o755)
        shutil.copy2(FIXTURE,previous/'farpane')
        process=launch(previous/'farpane','--server',uid=1000);self.children.append(process)
        self.stage();pid=self.service.process.pid
        with self.assertRaisesRegex(ValueError,'Another managed release'):self.apply()
        self.assertIsNone(process.poll());self.assertEqual(self.service.process.pid,pid);self.assert_old()

    def test_readonly_plan_does_not_rewrite_installation(self):
        self.stage()
        before={path:(path.lstat().st_mtime_ns,path.lstat().st_mode) for path in self.store.base.rglob('*')}
        with self.store.locked(read_only=True):plan=self.runtime.preflight(self.target,self.old)
        self.assertEqual(plan['current'],self.old);self.assertTrue(plan['service']['active'])
        self.assertEqual(before,{path:(path.lstat().st_mtime_ns,path.lstat().st_mode) for path in self.store.base.rglob('*')})

    def test_recovery_preserves_administrator_receipt_change(self):
        self.stage()
        with self.store.locked():self.store.begin(self.target,expected_current=self.old,service_snapshot=self.service.snapshot(self.runtime.allowed(self.old)),legacy_verify=legacy.verify)
        self.store.state.write_text('{"administrator":"changed"}\n');self.store.state.chmod(0o644)
        with self.assertRaisesRegex(ValueError,'receipt changed outside'):self.runtime.recover(maintenance=True)
        self.assertEqual(self.store.state.read_text(),'{"administrator":"changed"}\n')
        self.store.state.unlink();self.runtime.recover(maintenance=True);self.assert_old()


class UserDesktopTransactions(InstallTransactions):
    # Inherit the fixture setup/cleanup, not the parent test methods.
    def setUp(self):
        super().setUp()
        (self.source/'manifest.json').unlink()
        from native_user_install import FILES
        for key,relative in FILES.items():
            source=(ROOT/'Linux/packaging'/('org.farpane.FarPane.'+('desktop' if key=='desktop' else 'service')+'.in')
                    if key in ('desktop','dbus') else ROOT/'Linux/gui/resources'/('org.farpane.FarPane.'+key))
            shutil.copyfile(source,self.source/relative);(self.source/relative).chmod(0o644)
        self.target=native_bundle.seal(self.source)['artifact_id']
        self.stage();self.apply()
        self.user_home=self.root/'desktop-home';self.user_home.mkdir(mode=0o755);os.chown(self.user_home,1000,1000)

    def as_user(self,operation,*,failure=None):
        result=self.user_home/'operation-result.json'
        child=os.fork()
        if child==0:
            try:
                signal.alarm(20);os.setgroups([]);os.setgid(1000);os.setuid(1000)
                from native_user_install import UserIntegration
                integration=UserIntegration(self.store,self.user_home)
                value=operation(integration)
                result.write_text(json.dumps({'ok':True,'value':value}))
            except BaseException as error:
                result.write_text(json.dumps({'ok':False,'error':type(error).__name__+': '+str(error),'traceback':traceback.format_exc()}))
            finally:os._exit(0)
        _,status=os.waitpid(child,0);self.assertEqual(status,0)
        response=json.loads(result.read_text())
        if failure:self.assertFalse(response['ok']);self.assertIn(failure,response['error'])
        else:self.assertTrue(response['ok'],response.get('traceback'))
        return response.get('value')

    def prepare_legacy(self,integration):
        integration.write(integration.paths['desktop'],integration.legacy_desktop())
        auto=('[Desktop Entry]\nType=Application\nName=FarPane\nExec='+str(self.store.base/'farpane')+' --tray\nX-FarPane-Managed=true\n').encode()
        integration.write(integration.paths['autostart-farpane'],auto)
        integration.write(self.user_home/'.config/autostart/rustdesk.desktop',b'UNRELATED RUSTDESK AUTOSTART\n')

    def test_user_bind_idempotent_and_full_legacy_restore(self):
        self.as_user(self.prepare_legacy)
        original=(self.user_home/'.local/share/applications/org.farpane.FarPane.desktop').read_bytes()
        first=self.as_user(lambda user:user.bind(self.target,self.old))
        second=self.as_user(lambda user:user.bind(self.target,self.old))
        self.assertTrue(second['already_installed']);self.assertFalse(first['processes_started'])
        menu=self.user_home/'.local/share/applications/org.farpane.FarPane.desktop'
        self.assertIn(str(self.store.base/'releases'/self.target/'farpane').encode(),menu.read_bytes())
        self.assertNotIn(b'@FARPANE_RELEASE@',menu.read_bytes())
        self.assertFalse((self.user_home/'.config/autostart/farpane.desktop').exists())
        self.apply(target=self.old,old=self.target)
        self.as_user(lambda user:user.rollback())
        self.assertEqual(menu.read_bytes(),original)
        self.assertTrue((self.user_home/'.config/autostart/farpane.desktop').is_file())
        self.assertEqual((self.user_home/'.config/autostart/rustdesk.desktop').read_bytes(),b'UNRELATED RUSTDESK AUTOSTART\n')
        self.assertFalse((self.user_home/'.local/share/dbus-1/services/org.farpane.FarPane.service').exists())

    def test_user_private_group_layout_preserves_identity_and_rollback(self):
        def prepare(user):
            self.prepare_legacy(user)
            icons=user.data/'icons';icons.mkdir();icons.chmod(0o775)
            config=user.config/'farpane';config.mkdir();config.chmod(0o775)
            (config/'FarPane.toml').write_bytes(b'opaque existing identity fixture\n')
        self.as_user(prepare)
        self.as_user(lambda user:user.bind(self.target,self.old))
        icons=self.user_home/'.local/share/icons'
        config=self.user_home/'.config/farpane'
        self.assertEqual(icons.stat().st_mode&0o777,0o775)
        self.assertEqual(config.stat().st_mode&0o777,0o700)
        self.assertEqual((config/'FarPane.toml').read_bytes(),b'opaque existing identity fixture\n')
        self.apply(target=self.old,old=self.target)
        self.as_user(lambda user:user.rollback())
        self.assertEqual(icons.stat().st_mode&0o777,0o775)
        self.assertEqual(config.stat().st_mode&0o777,0o700)
        self.assertEqual((config/'FarPane.toml').read_bytes(),b'opaque existing identity fixture\n')

    def test_user_crashes_during_file_writes_and_commit(self):
        self.as_user(self.prepare_legacy)
        pid=self.service.process.pid
        for key in ('desktop','dbus','svg','png','autostart-farpane','receipt','committed'):
            with self.subTest(key=key):
                def crash(user):
                    write=user.write;journal=user.journal
                    def write_then_crash(path,data,mode=0o644):
                        write(path,data,mode)
                        if key in user.paths and path==user.paths[key]:raise PowerLoss(key)
                    def journal_then_crash(record):
                        journal(record)
                        if key=='committed' and record['phase']=='committed':raise PowerLoss(key)
                    with patch.object(user,'write',write_then_crash),patch.object(user,'journal',journal_then_crash):
                        user.bind(self.target,self.old)
                self.as_user(crash,failure='PowerLoss')
                self.as_user(lambda user:user.recover())
                self.assertEqual(pid,self.service.process.pid)
        self.assertTrue(self.as_user(lambda user:user.bind(self.target,self.old))['already_installed'])

    def test_user_custom_desktop_and_autostart_are_not_overwritten(self):
        def custom(user):user.write(user.paths['desktop'],b'[Desktop Entry]\nName=My launcher\n')
        self.as_user(custom)
        self.as_user(lambda user:user.bind(self.target,self.old),failure='unmanaged desktop entry')
        self.assertFalse((self.user_home/'.local/share/icons').exists())
        def custom_auto(user):
            user.write(user.paths['desktop'],None)
            user.write(user.paths['autostart-FarPane'],b'[Desktop Entry]\nName=Custom startup\n')
        self.as_user(custom_auto)
        self.as_user(lambda user:user.bind(self.target,self.old),failure='Unmanaged FarPane autostart')
        self.assertEqual((self.user_home/'.config/autostart/FarPane.desktop').read_bytes(),b'[Desktop Entry]\nName=Custom startup\n')

    def test_user_recovery_preserves_edits_and_wrong_system_generation(self):
        self.as_user(self.prepare_legacy);self.as_user(lambda user:user.bind(self.target,self.old))
        self.as_user(lambda user:user.rollback(),failure='System release differs')
        self.apply(target=self.old,old=self.target)
        self.as_user(lambda user:user.write(user.paths['desktop'],b'user edit after install\n'))
        self.as_user(lambda user:user.rollback(),failure='changed outside transaction')
        self.assertEqual((self.user_home/'.local/share/applications/org.farpane.FarPane.desktop').read_bytes(),b'user edit after install\n')

    def test_user_symlink_parent_refused(self):
        def inject(user):
            outside=self.user_home/'outside';outside.mkdir()
            (self.user_home/'.local').symlink_to(outside)
            user.bind(self.target,self.old)
        self.as_user(inject,failure='Untrusted user integration path')
        self.assertEqual(list((self.user_home/'outside').iterdir()),[])


def actual_bundle(output):
    source=Path(os.environ['FARPANE_NATIVE_TEST_ARTIFACT']).resolve(strict=True)
    assert source.is_relative_to(ROOT/'Build/Linux/artifacts')
    original=native_bundle.verify(source)
    units=Path('/opt/native-install-artifact-units');units.mkdir(mode=0o755)
    store=Store(Path('/opt/native-install-artifact'),units)
    staged=store.stage(source);target=staged['artifact_id']
    service=ServiceFixture(store);runtime=Coordinator(store,service,legacy.verify)
    # Bind the real package on the private filesystem while the service stays
    # inactive. Its root supervisor is deliberately not started by this test.
    activated=runtime.apply(target,expected_current=None,maintenance=True)
    release=store.base/'releases'/target
    home=Path('/opt/native-install-artifact-user');home.mkdir(mode=0o755);os.chown(home,1000,1000)
    env={'PATH':'/usr/bin:/bin','HOME':str(home),'XDG_CONFIG_HOME':str(home/'config'),
         'XDG_DATA_HOME':str(home/'data'),'XDG_STATE_HOME':str(home/'state'),'XDG_CACHE_HOME':str(home/'cache')}
    probes={}
    for executable,arg in (('farpane','--build-info'),('libexec/farpane-core','--build-info'),('libexec/farpane-core','--check-bundled-media')):
        result=subprocess.run(['setpriv','--reuid=1000','--regid=1000','--clear-groups',str(release/executable),arg],
                              env=env,capture_output=True,text=True,timeout=10,check=True)
        probes[executable+':'+arg]=json.loads(result.stdout)
    assert list(home.iterdir())==[],'Diagnostic probe created configuration'
    child=os.fork()
    if child==0:
        try:
            os.setgroups([]);os.setgid(1000);os.setuid(1000)
            from native_user_install import UserIntegration
            user=UserIntegration(store,home);result=user.bind(target,None)
            # Use the actual desktop loader already supplied by the GUI's GIO
            # runtime, with no launch, bus connection or extra test package.
            import ctypes
            gio=ctypes.CDLL('libgio-2.0.so.0');gobject=ctypes.CDLL('libgobject-2.0.so.0')
            gio.g_desktop_app_info_new_from_filename.argtypes=[ctypes.c_char_p]
            gio.g_desktop_app_info_new_from_filename.restype=ctypes.c_void_p
            gio.g_app_info_get_executable.argtypes=[ctypes.c_void_p];gio.g_app_info_get_executable.restype=ctypes.c_char_p
            gobject.g_object_unref.argtypes=[ctypes.c_void_p]
            info=gio.g_desktop_app_info_new_from_filename(os.fsencode(user.paths['desktop']))
            assert info,'GIO rejected installed desktop entry'
            try:assert gio.g_app_info_get_executable(info)==os.fsencode(release/'farpane')
            finally:gobject.g_object_unref(info)
            (home/'result.json').write_text(json.dumps({'result':result,'gio_desktop_parser':'pass'}))
            os._exit(0)
        except BaseException:
            (home/'error.txt').write_text(traceback.format_exc());os._exit(1)
    _,status=os.waitpid(child,0)
    assert status==0,(home/'error.txt').read_text() if (home/'error.txt').exists() else status
    # Binding creates a private product directory before the native owner starts,
    # but must not create or change identity/password configuration files.
    assert not (home/'config').exists(),'Diagnostic probes must not create XDG configuration'
    configuration=home/'.config/farpane'
    assert configuration.is_dir() and configuration.stat().st_mode&0o777==0o700
    assert list(configuration.iterdir())==[]
    assert service.process is None and service.events==['daemon-reload']
    assert native_bundle.verify(source)==original
    (output/'actual-bundle.json').write_text(json.dumps({'artifact':target,'probes':probes,
        'desktop':json.loads((home/'result.json').read_text()),'system_state':activated,
        'root_service_started':False,'host_modified':False,'source_unchanged':True},indent=2)+'\n')
    print('Real bundle staging, private activation, user probes, icons/menu/D-Bus binding and GIO desktop parsing: PASS',flush=True)


def main():
    if (not Path('/.dockerenv').exists() or os.geteuid()!=0
            or os.environ.get('FARPANE_INSTALL_TEST_ISOLATED')!='1' or Path('/opt/farpane').exists()):
        raise SystemExit('Requires owned test container, private PID namespace and empty private /opt')
    os.umask(0o022);FIXTURE.parent.mkdir(mode=0o755)
    output=Path(sys.argv[1]);output.mkdir(parents=True,exist_ok=False)
    fixture_source=native_bundle.digest(ROOT/'Linux/tests/native_install_fixture.c')
    cached=os.environ.get('FARPANE_INSTALL_TEST_FIXTURE')
    if cached:
        cached=Path(cached).resolve(strict=True)
        assert cached.is_relative_to(ROOT/'Build/Linux/native-install-smoke')
        receipt=json.loads(cached.with_suffix('.json').read_text())
        assert receipt=={'source_sha256':fixture_source,'binary_sha256':native_bundle.digest(cached)}
        shutil.copyfile(cached,FIXTURE)
    else:subprocess.run(['cc','-O2',str(ROOT/'Linux/tests/native_install_fixture.c'),'-o',str(FIXTURE)],check=True)
    FIXTURE.chmod(0o755)
    shutil.copy2(FIXTURE,output/'process-fixture')
    (output/'process-fixture.json').write_text(json.dumps({'source_sha256':fixture_source,'binary_sha256':native_bundle.digest(FIXTURE)},indent=2)+'\n')
    (output/'os-release.txt').write_bytes(Path('/etc/os-release').read_bytes())
    (output/'python-version.txt').write_text(sys.version+'\n')
    result=None;actual_passed=False
    try:
        with (output/'transactions.log').open('w') as stream:
            suite=unittest.defaultTestLoader.loadTestsFromTestCase(InstallTransactions)
            suite.addTests(UserDesktopTransactions(name) for name in UserDesktopTransactions.__dict__ if name.startswith('test_user_'))
            result=unittest.TextTestRunner(stream=stream,verbosity=2).run(suite)
        print((output/'transactions.log').read_text(),flush=True)
        if result.wasSuccessful() and os.environ.get('FARPANE_NATIVE_TEST_ARTIFACT'):
            actual_bundle(output);actual_passed=True
    except BaseException:
        (output/'error.txt').write_text(traceback.format_exc());raise
    finally:
        (output/'result.json').write_text(json.dumps({'tests':result.testsRun if result else 0,
            'failures':len(result.failures) if result else None,'errors':len(result.errors) if result else None,
            'actual_bundle_passed':actual_passed,'actual_bundle_requested':bool(os.environ.get('FARPANE_NATIVE_TEST_ARTIFACT')),
            'service_controller':'fixture; no actual systemd/logind acceptance','real_pidfds':True,'host_services_touched':False},indent=2)+'\n')
        for path in [output,*output.rglob('*')]:os.chown(path,int(sys.argv[2]),int(sys.argv[3]))
    raise SystemExit(0 if result and result.wasSuccessful() else 1)


if __name__=='__main__':main()
