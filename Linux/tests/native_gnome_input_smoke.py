"""Real Chinese paste in private headless Mutter/Xwayland, without host access."""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


def browser_target(directory):
    """Fresh Chrome profile, synthetic page, private container loopback only."""
    import http.server
    page = b'''<!doctype html><meta charset="utf-8"><input id="target" autofocus>
    <script>
    const field = document.querySelector('input');
    setInterval(() => fetch('/state', {method:'POST', body:JSON.stringify({
      text:field.value, active:document.hasFocus(),
      focused:document.activeElement === field, clipboard:null,
    })}),100);
    </script>'''
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8')
            self.end_headers();self.wfile.write(page)
        def do_POST(self):
            size = int(self.headers.get('Content-Length', '0'))
            assert 0 < size <= 16384
            state = json.loads(self.rfile.read(size))
            temporary = directory/'entry-next.json'
            temporary.write_text(json.dumps(state,ensure_ascii=False))
            temporary.replace(directory/'entry.json')
            self.send_response(204);self.end_headers()
    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    binary = '/opt/farpane-test-chrome/chrome'
    # No user's profile, extensions, network, compositor, bus or GPU is mounted.
    # The IBus guest mirrors linux-host, where Chrome picks GTK4 with im-ibus.
    gtk = '4' if Path('/usr/lib/x86_64-linux-gnu/gtk-4.0/4.0.0/immodules/libim-ibus.so').exists() else '3'
    browser = subprocess.Popen([binary, '--no-sandbox', '--disable-gpu', '--gtk-version='+gtk,
        '--disable-dev-shm-usage', '--no-first-run', '--no-default-browser-check',
        '--disable-background-networking', '--disable-features=Translate',
        '--ozone-platform=wayland', '--password-store=basic',
        '--user-data-dir='+str(directory/'browser-profile'),
        '--app=http://127.0.0.1:'+str(server.server_port)])
    try:server.serve_forever()
    finally:
        browser.terminate();browser.wait(timeout=5);server.server_close()


def terminal_child(directory):
    import tty
    tty.setraw(0)
    data = b''
    while True:
        data += os.read(0, 4096)
        temporary = directory/'terminal-next.txt'
        temporary.write_text(data.decode('utf-8', errors='replace'))
        temporary.replace(directory/'terminal-input.txt')


def terminal_target(directory):
    import gi
    gi.require_version('Gtk', '3.0')
    gi.require_version('Vte', '2.91')
    from gi.repository import Gtk, Gdk, GLib, Vte
    app = Gtk.Application(application_id='org.farpane.GnomeTerminalFixture')
    def activate(app):
        terminal = Vte.Terminal()
        window = Gtk.ApplicationWindow(application=app, title='FarPane private terminal')
        window.set_default_size(600, 220)
        window.add(terminal);window.show_all();terminal.grab_focus()
        terminal.spawn_async(Vte.PtyFlags.DEFAULT, str(directory),
            [sys.executable, __file__, '--terminal-child', str(directory)], None,
            GLib.SpawnFlags.DEFAULT, None, None, -1, None, None, None)
        clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        state = {'text':'', 'clipboard':None, 'seeded':False}
        def save():
            state.update(active=window.is_active(), focused=terminal.has_focus())
            received=directory/'terminal-input.txt'
            if received.exists():state['text']=received.read_text()
            if state['active'] and state['focused'] and not state['seeded'] and os.environ.get('FARPANE_GNOME_INPUT_SEED', '0') == '1':
                clipboard.set_text('private clipboard sentinel — unchanged', -1)
                state['seeded']=True
            clipboard.request_text(lambda c, text, _:state.update(clipboard=text), None)
            temporary=directory/'entry-next.json'
            temporary.write_text(json.dumps(state,ensure_ascii=False))
            temporary.replace(directory/'entry.json')
            return True
        GLib.timeout_add(100, save)
    app.connect('activate', activate)
    return app.run([])


def target(directory):
    if os.environ.get('FARPANE_GNOME_INPUT_TARGET')=='browser':
        return browser_target(directory)
    if os.environ.get('FARPANE_GNOME_INPUT_TARGET')=='terminal':
        return terminal_target(directory)
    import gi
    gi.require_version('Gtk', '4.0')
    from gi.repository import Gtk, GLib
    app = Gtk.Application(application_id='org.farpane.GnomeInputFixture')
    state = {'text': '', 'clipboard': None, 'seeded': False}
    def activate(app):
        entry = Gtk.Entry()
        entry.set_placeholder_text('Private Unicode input fixture')
        window = Gtk.ApplicationWindow(application=app, title='FarPane private text input')
        window.set_default_size(600, 220)
        window.set_child(entry)
        window.present()
        entry.grab_focus()
        clipboard = entry.get_clipboard()
        def save():
            state.update(text=entry.get_text(), active=window.is_active(),
                         focused=entry.get_delegate().has_focus())
            temporary = directory / 'entry-next.json'
            temporary.write_text(json.dumps(state, ensure_ascii=False))
            temporary.replace(directory / 'entry.json')
            return True
        def read_clipboard():
            if window.is_active() and entry.get_delegate().has_focus() and not state['seeded'] and os.environ.get('FARPANE_GNOME_INPUT_SEED', '0') == '1':
                clipboard.set('private clipboard sentinel — unchanged')
                state['seeded'] = True
            def ready(clipboard, result):
                try:state['clipboard'] = clipboard.read_text_finish(result)
                except Exception:state['clipboard'] = None
            clipboard.read_text_async(None, ready)
            return True
        GLib.timeout_add(100, save)
        GLib.timeout_add(250, read_clipboard)
    app.connect('activate', activate)
    return app.run([])


def exercise(output, binary):
    assert Path('/.dockerenv').is_file() and os.geteuid() != 0
    assert not Path('/dev/dri').exists() and not Path('/dev/uinput').exists()
    assert not os.environ.get('DISPLAY') and not os.environ.get('WAYLAND_DISPLAY')
    runtime = Path('/run/farpane-native-test/user')
    runtime.mkdir(mode=0o700)
    home = runtime / 'home';home.mkdir(mode=0o700)
    output.mkdir(parents=True)
    env = dict(os.environ, HOME=str(home), XDG_RUNTIME_DIR=str(runtime),
               XDG_CONFIG_HOME=str(home/'config'), XDG_CACHE_HOME=str(home/'cache'),
               XDG_DATA_HOME=str(home/'data'), XDG_STATE_HOME=str(home/'state'),
               XDG_SESSION_TYPE='wayland', XDG_CURRENT_DESKTOP='GNOME',
               LIBGL_ALWAYS_SOFTWARE='1', GALLIUM_DRIVER='llvmpipe',
               GTK_A11Y='none', NO_AT_BRIDGE='1', GSETTINGS_BACKEND='keyfile',
               DBUS_SESSION_BUS_ADDRESS='unix:path='+str(runtime/'bus'),
               DBUS_SYSTEM_BUS_ADDRESS='unix:path='+str(runtime/'bus'))
    processes=[];logs=[]
    def start(label, args, environment=env):
        log=(output/(label+'.log')).open('wb');logs.append(log)
        process=subprocess.Popen(args, env=environment, stdout=log, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        processes.append(process);return process
    def wait(predicate, message, seconds=20):
        deadline=time.monotonic()+seconds
        while time.monotonic()<deadline:
            value=predicate()
            if value:return value
            time.sleep(.05)
        raise RuntimeError(message)
    try:
        start('bus', ['dbus-daemon','--session','--nofork',
                     '--address='+env['DBUS_SESSION_BUS_ADDRESS']])
        wait(lambda:(runtime/'bus').is_socket(), 'Private bus did not start')
        subprocess.run(['gsettings','set','org.gnome.shell',
                        'welcome-dialog-last-shown-version','50.1'],env=env,check=True,timeout=5)
        shell=start('gnome',['mutter','--headless','--wayland',
                            '--virtual-monitor=1020x720'])
        def socket():
            if shell.poll() is not None:raise RuntimeError('Private GNOME exited; see gnome.log')
            paths=[p for p in runtime.glob('wayland-*') if p.is_socket()]
            return paths[0] if len(paths)==1 else None
        wayland=wait(socket,'Private GNOME did not create a Wayland display')
        time.sleep(2)
        assert shell.poll() is None, 'GNOME did not complete initialization'
        managed = re.search(r'using (unix:/tmp/\.X11-unix/X[0-9]+) for managed services',
                            (output/'gnome.log').read_text()).group(1)
        authority = list(runtime.glob('.mutter-Xwaylandauth.*'))
        assert len(authority)==1, 'Expected private Mutter Xwayland authority'
        env.update(WAYLAND_DISPLAY=wayland.name,GDK_BACKEND='wayland',GSK_RENDERER='cairo',
                   DISPLAY=managed, XAUTHORITY=str(authority[0]),
                   FARPANE_GNOME_MANAGED_DISPLAY=managed)
        start('entry',[sys.executable,__file__,'--target',str(output)])
        wait(lambda:(output/'entry.json').exists(),'Private entry did not start')
        # GNOME may initially show its overview. Give the owned target focus
        # through its real private virtual keyboard, never shell Eval or a
        # host input device. Keep the D-Bus connection alive for the session.
        from gi.repository import Gio, GLib
        bus=Gio.DBusConnection.new_for_address_sync(env['DBUS_SESSION_BUS_ADDRESS'],
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT|Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            None,None)
        service='org.gnome.Mutter.RemoteDesktop'
        session_interface=service+'.Session'
        def call(path,interface,method,args=None):
            return bus.call_sync(service,path,interface,method,args,None,
                                 Gio.DBusCallFlags.NONE,1000,None)
        focus_session=call('/org/gnome/Mutter/RemoteDesktop',service,'CreateSession').unpack()[0]
        call(focus_session,session_interface,'Start')
        def key(code,down):
            call(focus_session,session_interface,'NotifyKeyboardKeycode',GLib.Variant('(ub)',(code,down)))
            time.sleep(.08)
        key(56,True);key(15,True);key(15,False);key(56,False)
        time.sleep(.4)
        def focused():
            try:
                v=json.loads((output/'entry.json').read_text())
                return v if v['active'] and v['focused'] and (v['clipboard'] or os.environ.get('FARPANE_GNOME_INPUT_SEED', '0') == '0') else None
            except (OSError,ValueError,KeyError):return None
        initial=wait(focused,'Private entry did not gain keyboard focus')
        (output/'entry-before.json').write_text(json.dumps(initial,ensure_ascii=False,indent=2)+'\n')
        if binary:
            env['FARPANE_GNOME_INPUT_TEST_DIR']=str(output)
            with (output/'core-input-test.log').open('w') as log:
                result=subprocess.run([str(binary),
                    os.environ.get('FARPANE_GNOME_INPUT_TEST', 'server::input_service::native_paste_tests::private_mutter_production_paste'),
                    '--exact','--ignored','--nocapture'],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=30)
            assert result.returncode==0,'Core Unicode test failed; see core-input-test.log'
            assert (output/'gnome-input-result.json').is_file()
        call(focus_session,session_interface,'Stop')
        print(json.dumps({'private_gnome_started':True,'focused_entry':True,
                          'target':os.environ.get('FARPANE_GNOME_INPUT_TARGET','entry'),
                          'core_input_exercised':bool(binary),'host_access':False,'gpu':False}))
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                os.killpg(process.pid,signal.SIGTERM)
        for process in reversed(processes):
            try:process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=3)
        for log in logs:log.close()


if __name__=='__main__':
    if sys.argv[1]=='--terminal-child':terminal_child(Path(sys.argv[2]))
    if sys.argv[1]=='--target':raise SystemExit(target(Path(sys.argv[2])))
    exercise(Path(sys.argv[1]),Path(sys.argv[2]) if len(sys.argv)>2 else None)
