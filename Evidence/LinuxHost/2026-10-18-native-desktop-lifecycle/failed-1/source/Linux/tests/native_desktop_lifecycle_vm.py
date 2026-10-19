"""Real GNOME single-instance/window-close checks in a marked private kernel."""
import json
from pathlib import Path
import re
import subprocess
import time

from native_desktop_launch_vm import Keyboard, capture, require_probe
from native_input_vm_desktop import OUTPUT, wait
from native_maintenance_vm import processes, require_maintenance


def require_lifecycle():
    _, marker = require_maintenance()
    assert marker.get('desktop_lifecycle_probe') is True
    require_probe()


def exercise(env, release, gnome_pid):
    require_lifecycle()  # Before keyboard, capture, journal, GUI or D-Bus calls.
    root = Path('/opt/farpane/releases') / release
    prefix = ['setpriv', '--reuid=1000', '--regid=1000', '--clear-groups']
    stable = [p for p in processes(release) if p['role'] in ('--service', '--server')]
    assert len(stable) == 2
    report = {'result': 'fail', 'checks': [], 'states': [], 'captures': [], 'traces': []}
    companion = None
    keyboard = None
    companion_log = None

    def user(args, *, input=None):
        p = subprocess.run(prefix + list(map(str, args)), env=env, input=input,
                           capture_output=True, text=True, timeout=10)
        assert p.returncode == 0, (args, p.stderr)
        return p.stdout

    def activation_environment(value):
        user(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus',
              '--object-path', '/org/freedesktop/DBus', '--method',
              'org.freedesktop.DBus.UpdateActivationEnvironment',
              "{'WAYLAND_DEBUG': '" + value + "'}"])

    def identity():
        data = json.loads(user([root / 'libexec/farpane-core', '--config-cli'],
                              input=json.dumps({'type': 'snapshot'})))
        assert data['role'] == 'agent' and data['host_enabled']
        return {k: data[k] for k in ('local_id', 'permanent_password_set', 'authentication')}

    expected = identity()

    def gui():
        found = [p for p in processes(release) if p['role'] == 'gui']
        assert len(found) <= 1, 'Multiple native GUI processes'
        return found[0] if found else None

    def record(name, expected_gui):
        assert [p for p in processes(release) if p['role'] in ('--service', '--server')] == stable
        assert identity() == expected
        assert gui() == expected_gui
        report['states'].append({'phase': name, 'processes': processes(release),
                                 'identity_unchanged': True})

    def picture(name):
        report['captures'].append(capture(release, 'launch-life-' + name))

    def menu():
        keyboard.key(1); time.sleep(.2)
        keyboard.key(125); time.sleep(.5)
        for code in (33, 30, 19, 25, 30, 49, 18): keyboard.key(code)
        time.sleep(.8); keyboard.key(28)
        current = wait(gui, 'GNOME menu did not start the native GUI', 10)
        def owns_bus():
            p = subprocess.run(prefix + ['gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus',
                '--object-path', '/org/freedesktop/DBus', '--method',
                'org.freedesktop.DBus.GetConnectionUnixProcessID', 'org.farpane.FarPane'],
                env=env, capture_output=True, text=True, timeout=5)
            if p.returncode:
                assert 'NameHasNoOwner' in p.stderr, p.stderr
                return False
            assert re.fullmatch(r'\(uint32 ' + str(current['pid']) + r',\)\s*', p.stdout)
            return True
        wait(owns_bus, 'GUI did not register its application bus name', 5)
        time.sleep(1)
        return current

    def trace(process, *, closed):
        p = subprocess.run(['journalctl', '-b', '--no-pager', '-o', 'cat',
                            '_PID=' + str(process['pid'])], capture_output=True, text=True, timeout=5)
        assert p.returncode == 0
        name = 'desktop-lifecycle-wayland-' + str(process['pid']) + ('-closed' if closed else '-open') + '.log'
        (OUTPUT / name).write_text(p.stdout)
        assert len(p.stdout.encode()) <= 1024 * 1024, 'Wayland trace exceeded export bound'
        tops = re.findall(r'get_toplevel\(new id xdg_toplevel[@#]([0-9]+)\)', p.stdout)
        assert len(tops) == 1, ('Expected one actual Wayland toplevel', tops)
        top = r'xdg_toplevel[@#]' + tops[0]
        assert re.search(top + r'\.set_app_id\("org\.farpane\.FarPane"\)', p.stdout)
        assert re.search(top + r'\.set_title\("FarPane"\)', p.stdout)
        destroyed = bool(re.search(top + r'\.destroy\(\)', p.stdout))
        assert not closed or destroyed, 'Window close did not destroy its Wayland toplevel'
        item = {'pid': process['pid'], 'file': name, 'toplevels_created': len(tops),
                'app_id': 'org.farpane.FarPane', 'destroyed': destroyed}
        report['traces'].append(item)

    def close_gui(process):
        began = time.monotonic()
        keyboard.alt_key(62)
        wait(lambda: not Path('/proc', str(process['pid'])).exists(),
             'Alt-F4 left the GUI process alive', 20)
        assert gui() is None
        query = subprocess.run(prefix + ['gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus',
            '--object-path', '/org/freedesktop/DBus', '--method',
            'org.freedesktop.DBus.NameHasOwner', 'org.farpane.FarPane'],
            env=env, capture_output=True, text=True, timeout=5)
        assert query.returncode == 0 and query.stdout.strip() == '(false,)'
        report.setdefault('close_seconds', []).append(round(time.monotonic() - began, 3))
        trace(process, closed=True)

    try:
        activation_environment('client')
        keyboard = Keyboard(gnome_pid)
        first = menu(); record('initial-menu', first); picture('menu')
        report['checks'].append('gnome_menu_opens_one_native_gui_attached_to_host')
        for _ in range(2): assert menu() == first
        record('repeated-menu', first)
        report['checks'].append('repeated_gnome_menu_keeps_same_gui_generation')
        user([root / 'farpane'])
        time.sleep(.3); record('direct-entry-existing-instance', first); picture('repeat')
        trace(first, closed=False)
        report['checks'].append('direct_executable_reuses_one_wayland_toplevel_and_app_id')

        state = OUTPUT / 'lifecycle-companion.json'
        script = '''import gi,json,sys
gi.require_version('Gtk','4.0')
from gi.repository import Gtk
from pathlib import Path
state=Path(sys.argv[1])
app=Gtk.Application(application_id='org.farpane.TestCompanion')
def activate(app):
 window=Gtk.ApplicationWindow(application=app,title='Private reference window',default_width=360,default_height=180)
 window.set_child(Gtk.Label(label='Private GNOME lifecycle test'))
 def save(*args):
  temp=state.with_suffix('.tmp');temp.write_text(json.dumps({'active':window.is_active()}));temp.replace(state)
 window.connect('notify::is-active',save)
 window.present();save()
app.connect('activate',activate)
app.run([])
'''
        companion_log = (OUTPUT / 'desktop-lifecycle-companion.log').open('w')
        companion = subprocess.Popen(prefix + ['python3', '-c', script, str(state)], env=env,
                                     stdout=companion_log, stderr=subprocess.STDOUT)
        wait(state.exists, 'Private companion window did not start', 10)
        def active():
            assert companion.poll() is None, 'Private companion exited'
            return json.loads(state.read_text())['active']
        time.sleep(.5)
        if not active(): keyboard.alt_key(15)
        wait(active, 'GNOME did not focus the companion through Alt-Tab', 5)
        keyboard.alt_key(15, lambda: picture('switcher'))
        wait(lambda: not active(), 'GNOME did not switch from companion to FarPane', 5)
        time.sleep(.4); picture('returned'); record('alt-tab-returned', first)
        report['checks'].append('real_alt_tab_switches_between_companion_and_farpane')

        close_gui(first); record('first-close', None); picture('closed')
        report['checks'].append('alt_f4_destroys_window_removes_gui_and_bus_owner_preserves_host')
        companion.terminate(); companion.wait(timeout=5)
        second = menu()
        assert second != first and not Path('/proc', str(first['pid'])).exists()
        record('reopened', second); picture('reopened')
        report['checks'].append('menu_reopens_new_gui_on_original_host_and_identity')
        assert menu() == second
        close_gui(second); record('final-close', None)
        report['checks'].append('reopened_gui_remains_single_instance_and_exits_without_hidden_process')
        report.update(result='pass', host_generation_unchanged=True,
                      input_text_tested=False, remote_connection_tested=False,
                      diagnostic_activation_environment={'WAYLAND_DEBUG': 'client'},
                      memory_budget_tested=False)
        return report
    finally:
        if keyboard is not None: keyboard.close()
        if companion is not None and companion.poll() is None:
            companion.terminate(); companion.wait(timeout=5)
        if companion_log is not None: companion_log.close()
        (OUTPUT / 'desktop-lifecycle-result.log').write_text(json.dumps(report, indent=2))
        activation_environment('')
