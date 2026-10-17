"""Actual GUI shortcut inhibition against an owned Sway compositor."""
import json
import os
from pathlib import Path
import subprocess
import time

from native_host_smoke import RELEASE, RUNTIME, cli
from native_lifecycle_smoke import children, colored_pixels
from native_wayland_fixture import PrivateWayland


def exercise(output, start, agent, initial):
    config = output / 'sway.conf'
    config.write_text('xwayland disable\noutput HEADLESS-1 resolution 1020x720\n'
        'seat seat0 fallback true\nseat seat0 shortcuts_inhibitor disable\n'
        'default_border none\nfocus_follows_mouse no\n')
    env = dict(os.environ, WLR_BACKENDS='headless', WLR_RENDERER='pixman',
               WLR_LIBINPUT_NO_DEVICES='1', XDG_SESSION_TYPE='wayland')
    compositor = start('keyboard-compositor', ['sway', '-d', '--config', str(config)], env)
    deadline = time.monotonic() + 8
    while True:
        sockets = [p for p in RUNTIME.glob('wayland-*') if p.is_socket()]
        ipc = [p for p in RUNTIME.glob('sway-ipc.*.sock') if p.is_socket()]
        if len(sockets) == len(ipc) == 1:
            break
        assert compositor.poll() is None and time.monotonic() < deadline
        time.sleep(.05)
    screen = PrivateWayland(sockets[0])
    env.update(WAYLAND_DISPLAY=sockets[0].name, GDK_BACKEND='wayland', GSK_RENDERER='cairo',
               GTK_A11Y='none', WAYLAND_DEBUG='1')
    gui = start('keyboard-gui', [str(RELEASE / 'farpane')], env)
    diagnostic = Path(os.environ['XDG_STATE_HOME']) / 'farpane/native/viewer.log'
    protocol = output / 'keyboard-gui.log'
    events = []

    def command(text, require=True):
        result = subprocess.run(['swaymsg', '-s', str(ipc[0]), '-r', text],
                                capture_output=True, text=True, timeout=4)
        replies = json.loads(result.stdout)
        ok = result.returncode == 0 and all(item['success'] for item in replies)
        if require:
            assert ok, (text, result.stdout, result.stderr)
        events.append({'command': text, 'success': ok, 'reply': replies})
        return ok

    def click(x, y):
        command(f'seat seat0 cursor set {x} {y}')
        command('seat seat0 cursor press button1')
        command('seat seat0 cursor release button1')
        time.sleep(.15)

    def wait(predicate, message, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert gui.poll() is None and agent.poll() is None and compositor.poll() is None
            value = predicate()
            if value:
                return value
            time.sleep(.08)
        screen.capture(output / 'failure.png')
        raise AssertionError(message)

    def text():
        return protocol.read_text()

    def request():
        before = text().count('.inhibit_shortcuts(')
        click(573, 77)
        wait(lambda: text().count('.inhibit_shortcuts(') > before, 'Actual exclusive button did not request inhibition')

    def no_inhibitor(label):
        ok = command('seat seat0 shortcuts_inhibitor activate', False)
        time.sleep(.15)
        screen.capture(output / (label + '.png'))
        assert not ok, label + ': compositor still has a cancelled inhibitor'

    try:
        wait(lambda: 'org.farpane.FarPane' in subprocess.check_output(
            ['swaymsg', '-s', str(ipc[0]), '-t', 'get_tree'], text=True), 'GUI did not appear')
        time.sleep(1)
        screen.capture(output / 'home.png')
        click(430, 252);screen.type('127.0.0.1:21118');click(824, 252)
        wait(lambda: diagnostic.exists() and 'PasswordRequired' in diagnostic.read_text(), 'No password challenge')
        click(485, 233);screen.type('native-viewer-smoke');click(510, 387)
        pixels = wait(lambda: (n if (n := colored_pixels(screen.capture(), 0x205090)) > 15000 else 0),
                      'Actual Wayland Viewer did not render remote content')
        worker = wait(lambda: children(gui.pid), 'Viewer child missing')[0]
        assert Path(f'/proc/{worker}/exe').resolve() == RELEASE / 'libexec/farpane-core'
        screen.capture(output / 'streaming.png')
        began = time.monotonic()
        request()
        time.sleep(15.25)
        screen.capture(output / 'request-timed-out.png')
        no_inhibitor('late-authorization-after-timeout')
        events.append({'timeout_wait_seconds': time.monotonic() - began})

        request();time.sleep(2)
        assert command('seat seat0 shortcuts_inhibitor activate', False), 'Desktop confirmation was cancelled too early'
        time.sleep(.2)
        screen.capture(output / 'delayed-granted.png')
        click(573, 77)
        no_inhibitor('delayed-grant-cancel')

        command('seat seat0 shortcuts_inhibitor enable')
        before = text().count('.active()')
        request()
        wait(lambda: text().count('.active()') > before, 'Compositor did not grant shortcuts')
        screen.capture(output / 'granted.png')
        click(573, 77)
        no_inhibitor('user-cancel')

        request()
        command('seat seat0 shortcuts_inhibitor deactivate')
        time.sleep(.2)
        no_inhibitor('compositor-revoked')

        # A timer from an earlier cancelled request must not cancel this one.
        command('seat seat0 shortcuts_inhibitor disable')
        first_request = time.monotonic()
        request();time.sleep(.15)
        click(573, 77)
        request()
        time.sleep(max(0, first_request + 15.15 - time.monotonic()))
        assert command('seat seat0 shortcuts_inhibitor activate', False), 'Old timeout cancelled the replacement request'
        time.sleep(.2)
        screen.capture(output / 'replacement-granted.png')
        click(573, 77)
        no_inhibitor('replacement-cancel')

        command('seat seat0 shortcuts_inhibitor enable')
        request()
        command('workspace number 2');time.sleep(.2)
        command('workspace number 1');time.sleep(.2)
        no_inhibitor('window-deactivated')

        request()
        click(80, 28)
        wait(lambda: not children(gui.pid) and not Path(f'/proc/{worker}').exists(), 'Viewer was not reaped')
        wait(lambda: not cli({'type': 'snapshot'})['inbound'], 'Host retained inbound session')
        no_inhibitor('disconnect')
        command('[app_id="org.farpane.FarPane"] kill')
        assert gui.wait(timeout=8) == 0 and agent.poll() is None
        result = dict(result='pass', remote_pixels=pixels, worker_reaped=True, host_retained=True,
            checks=['timeout-destroys-pending-inhibitor', 'delayed-desktop-confirmation', 'actual-grant', 'user-cancel',
                    'compositor-revocation', 'old-timeout-cannot-cancel-new-request',
                    'window-deactivation', 'disconnect'], private_wayland=True, gpu=False)
        (output / 'keyboard-result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result), flush=True)
    finally:
        (output / 'compositor-commands.json').write_text(json.dumps(events, indent=2) + '\n')
        screen.close()
