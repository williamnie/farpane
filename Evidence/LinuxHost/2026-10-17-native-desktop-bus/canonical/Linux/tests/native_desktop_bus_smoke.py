"""Restart an entire private Host session bus while real approval/video runs.

The controller and remote Viewer use other private buses. This deliberately
tests the Host desktop adapter, not GTK surviving loss of its own session bus.
"""
import json
import os
from pathlib import Path
import threading
import time

from gi.repository import Gio, GLib
from native_desktop_smoke import Services, call, connection, read, wait, GUI
from native_host_smoke import RELEASE, RUNTIME, cli


class PrivateBus:
    def __init__(self, output, start):
        assert Path('/.dockerenv').is_file() and os.geteuid() != 0
        self.output, self.start_process = output, start
        self.path = RUNTIME/'desktop-bus'
        # Same path with a new bus ID, like a socket-activated user bus. An
        # address pinned to an old GUID is a different, untested scenario.
        self.address = 'unix:path='+str(self.path)
        self.generation = 0
        self.process = None
        self.start()

    def start(self):
        assert self.process is None or self.process.poll() is not None
        self.path.unlink(missing_ok=True)
        self.generation += 1
        self.process = self.start_process('desktop-bus-'+str(self.generation),
            ['dbus-daemon', '--session', '--nofork', '--address='+self.address])
        wait(lambda:self.path.exists(), 'Private session bus did not start')
        assert self.process.poll() is None

    def stop(self):
        assert self.process.poll() is None
        self.process.terminate()
        assert self.process.wait(timeout=5) == 0

    def connect(self):
        client = Gio.DBusConnection.new_for_address_sync(self.address,
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            None, None)
        client.set_exit_on_close(False)
        return client

    def provider(self):
        old = os.environ['DBUS_SESSION_BUS_ADDRESS']
        try:
            os.environ['DBUS_SESSION_BUS_ADDRESS'] = self.address
            provider = Services(self.output, self.generation)
            provider.c.set_exit_on_close(False)
            return provider
        finally:
            os.environ['DBUS_SESSION_BUS_ADDRESS'] = old


def exercise(output, agent, start, bus):
    loop = GLib.MainLoop()
    thread = threading.Thread(target=loop.run, daemon=True)
    thread.start()
    providers, clients, bus_ids, checks = [], [], [], []
    controller = connection()
    controller.set_exit_on_close(False)
    baseline = cli({'type':'snapshot'})
    baseline = cli({'type':'set_authentication', 'data':{
        'mode':'approval', 'password':None, 'revision':baseline['revision']}})
    history = []

    def snapshot():
        assert agent.poll() is None, 'Session bus failure terminated the Host'
        value = cli({'type':'snapshot'})
        sample = {'at':time.monotonic(), 'desktop':value['desktop'],
                  'inbound':[{k:c[k] for k in ('id','authorized')} for c in value['inbound']]}
        history.append(sample)
        return value

    def provider():
        client = bus.connect(); clients.append(client)
        bus_ids.append(call(client,'org.freedesktop.DBus','/org/freedesktop/DBus','org.freedesktop.DBus','GetId')[0])
        item = bus.provider(); providers.append(item)
        wait(lambda:item.registrations and snapshot()['desktop']['notification_actions'],
             'Host did not register on the new session bus', 14)
        return item

    def viewer(name):
        directory = output/name; directory.mkdir()
        env = dict(os.environ, DISPLAY=':92', GSK_RENDERER='cairo', GTK_A11Y='none',
                   FARPANE_NATIVE_TEST_MODE='recovery',
                   FARPANE_VIEWER_SMOKE_DIR=str(directory), FARPANE_DESKTOP_SMOKE_DIR=str(directory))
        process = start(name, ['dbus-run-session','--',str(RELEASE/'farpane')], env)
        return process, directory

    def pending():
        items = snapshot()['inbound']
        return items if items and all(not c['authorized'] for c in items) else None

    def offline():
        state = snapshot()['desktop']
        return not any(state[k] for k in ('connected','tray_registered','notifications_available','notification_actions'))

    try:
        first = provider()
        checks.append('host_on_independent_private_session_bus')
        process, video = viewer('approved-viewer')
        request = wait(pending, 'Approval request missing', 18)
        wait(lambda:first.notifications, 'Initial notification missing')
        request_id = request[0]['id']
        bus.stop()
        wait(offline, 'Host did not report the whole bus unavailable')
        assert first.c.is_closed() and clients[-1].is_closed()
        deadline = time.monotonic()+5.5
        while time.monotonic()<deadline:
            state = snapshot()
            assert [c['id'] for c in state['inbound']] == [request_id]
            assert not state['inbound'][0]['authorized']
            assert not read(video/'viewer-progress.json').get('presented',False)
            time.sleep(.2)
        checks += ['bus_disconnection_clears_desktop_capabilities','pending_request_not_auto_authorized_during_outage']
        bus.start(); second = provider()
        wait(lambda:second.notifications, 'Pending request not notified on replacement bus')
        assert bus_ids[0] != bus_ids[1]
        assert [c['id'] for c in snapshot()['inbound']] == [request_id]
        assert not snapshot()['inbound'][0]['authorized']
        assert len(second.notifications) == 1
        checks.append('new_bus_identity_rebinds_tray_and_pending_notice_without_new_host')

        # Approve through the real GTK control dialog on an unaffected private
        # bus. Notification and SNI methods never grant access themselves.
        home = output/'controller'; home.mkdir()
        env = dict(os.environ,DISPLAY=':92',GSK_RENDERER='cairo',GTK_A11Y='none',
                   FARPANE_DESKTOP_SMOKE_DIR=str(home))
        gui = start('controller',[str(RELEASE/'farpane')],env)
        wait(lambda:read(home/'desktop-progress.json').get('connected'),'Controller GUI unavailable')
        call(controller, GUI, '/org/farpane/FarPane', 'org.freedesktop.Application',
             'ActivateAction', '(sava{sv})', ('show-connections',[],{}))
        wait(lambda:'本机连接与权限' in read(home/'desktop-progress.json').get('dialogs',[]),'Actual controls not opened')
        (home/'approve').touch()
        wait(lambda:(video/'viewer-window.png').exists(), 'GTK approval did not present video', 15)
        wait(lambda:second.notifications[0]['id'] in second.closed,'Authorized notification was not closed')
        checks.append('actual_gtk_approval_after_bus_recovery_presents_video')

        # Bus failure during an already authorized session must neither revoke
        # nor replace that network session, and must not stop video delivery.
        before = read(video/'viewer-progress.json')['frames']
        bus.stop(); wait(offline, 'Second bus loss not reflected')
        start('new-frame-during-outage',['xmessage','-display',':91','-geometry','300x110+15+15','Session bus offline, same video connection'])
        wait(lambda:read(video/'viewer-progress.json').get('frames',0)>before,'Video stopped with session bus')
        assert [c['id'] for c in snapshot()['inbound']] == [request_id]
        assert snapshot()['inbound'][0]['authorized']
        checks.append('authorized_session_continues_presenting_during_bus_outage')
        bus.start(); third = provider()
        assert len(set(bus_ids)) == 3
        assert not third.notifications, 'Already authorized session was notified as pending'
        assert snapshot()['inbound'][0]['authorized']
        checks.append('restored_bus_does_not_replay_authorized_request')
        (video/'clipboard-complete').touch()
        assert process.wait(timeout=15) == 0
        result = read(video/'viewer.json')
        assert result['presented'] and result['worker_reaped'] and result['frames']>before
        wait(lambda:not snapshot()['inbound'],'Authorized Viewer not removed')

        process, video = viewer('unanswered-viewer')
        wait(pending, 'Second approval request missing', 18)
        wait(lambda:third.notifications,'Second approval notification missing')
        began = time.monotonic(); bus.stop(); wait(offline, 'Third bus loss not reflected')
        result = wait(lambda:read(video/'viewer.json'), 'Approval did not time out without the bus', 40)
        elapsed = time.monotonic()-began
        assert elapsed>24 and not result['presented'] and result['frames']==0 and result['worker_reaped']
        assert not snapshot()['inbound']
        (video/'close-window').touch(); assert process.wait(timeout=15)==0
        checks.append('unanswered_request_times_out_without_bus_or_frames')
        bus.start(); fourth = provider()
        # Two normal refresh intervals after registration: no stale pending
        # connection is allowed to become a fresh notification.
        deadline=time.monotonic()+1.2
        while time.monotonic()<deadline:
            assert not snapshot()['inbound'] and not fourth.notifications
            time.sleep(.2)
        assert len(set(bus_ids)) == 4
        checks.append('expired_request_not_replayed_on_fourth_bus')
        (home/'close-window').touch(); assert gui.wait(timeout=15)==0
        after = snapshot()
        for key in ('local_id','host_enabled','authentication','permanent_password_set','server','sharing','gpu_enabled'):
            assert after[key] == baseline[key], key
        checks.append('host_identity_policy_and_process_preserved')
        report = {'result':'pass','checks':checks,'host_pid':agent.pid,'bus_ids':bus_ids,
                  'approval_timeout_seconds_after_bus_loss':elapsed,
                  'scope':'Host desktop adapter; GUI and Viewer use unaffected private buses',
                  'gpu':False,'display':'two-private-xvfb','network':'private-loopback'}
        (output/'desktop-bus-result.json').write_text(json.dumps(report,indent=2)+'\n')
        print(json.dumps(report,indent=2))
    finally:
        (output/'desktop-history.json').write_text(json.dumps(history,indent=2)+'\n')
        for item in providers:
            (output/f'provider-{item.serial}.json').write_text(json.dumps({
                'registrations':item.registrations,'notifications':item.notifications,
                'closed':item.closed,'errors':item.errors},indent=2)+'\n')
            if not item.c.is_closed(): item.c.close_sync(None)
        for client in clients+[controller]:
            if not client.is_closed(): client.close_sync(None)
        loop.quit(); thread.join(timeout=2)
