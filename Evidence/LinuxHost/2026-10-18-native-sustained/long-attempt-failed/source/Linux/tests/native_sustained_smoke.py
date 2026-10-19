"""One continuous real Viewer session, external pixels, no product test hooks.

The short 60-second mode validates the fixture; it cannot pass the 30-minute
gate. Both modes use private Xvfb, software media and synthetic configuration.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import time

from native_host_smoke import RELEASE, cli
from native_lifecycle_smoke import Display, children, colored_pixels, sample


def guard():
    if (not Path('/.dockerenv').is_file() or os.geteuid() == 0
            or os.environ.get('FARPANE_NATIVE_TEST_MODE') != 'sustained'
            or os.environ.get('XDG_RUNTIME_DIR') != '/run/farpane-native-test/user'
            or os.environ.get('HOME') != '/run/farpane-native-test/user'
            or any(Path(p).exists() for p in ('/dev/dri', '/dev/input', '/dev/uinput', '/dev/kvm'))
            or os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY')):
        raise ValueError('Requires the private software-only sustained-test container')
    seconds = int(os.environ.get('FARPANE_SUSTAINED_SECONDS', '0'))
    if seconds not in (60, 1800):
        raise ValueError('Only a 60-second fixture check or 1800-second session is accepted')
    return seconds


def color_for(index):
    # Unique colors separated by >= 44/channel exceed the +/-12 pixel tolerance;
    # a stale immediately preceding frame cannot satisfy the new challenge.
    # Exclude near-gray colors that would also match the application's chrome.
    levels = range(16, 237, 44)
    colors = [(red << 16) | (green << 8) | blue
              for red in levels for green in levels for blue in levels
              if max(red, green, blue) - min(red, green, blue) >= 88]
    if not 0 <= index < len(colors):
        raise ValueError('Unique challenge palette exhausted')
    return colors[index]


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def exercise(output, start, agent, initial):
    seconds = guard()
    env = dict(os.environ, DISPLAY=':92', GSK_RENDERER='cairo', GTK_A11Y='none',
               GTK_IM_MODULE='gtk-im-context-simple', RUST_LOG='info')
    if any(k.startswith('FARPANE_') and ('SMOKE_DIR' in k or 'SMOKE_EXIT' in k
           or 'SMOKE_REPORT' in k or 'MEMORY_PROBE' in k) for k in env):
        raise ValueError('Product test hooks must remain disabled')
    gui = start('sustained-gui', [str(RELEASE / 'farpane')], env)
    screen, remote = Display(':92'), Display(':91')
    pattern = remote.x.XCreateSimpleWindow(remote.display, remote.root, 80, 100, 480, 260, 0, 0, 0)
    remote.x.XMapRaised(remote.display, pattern)
    remote.x.XSync(remote.display, 0)
    records = []
    worker = None
    began = None
    result = {'result': 'running', 'requested_seconds': seconds, 'thirty_minute_gate': False,
              'gpu_tested': False, 'root_service_tested': False, 'real_desktop_tested': False,
              'product_test_hooks': False, 'software_only': True, 'network': 'private-loopback'}

    def wait(predicate, message, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert gui.poll() is None and agent.poll() is None, 'GUI/Host exited: ' + message
            found = predicate()
            if found:
                return found
            time.sleep(.1)
        screen.capture(output / 'failure-screen.png')
        raise AssertionError(message)

    def window():
        tree = subprocess.check_output(['xwininfo', '-display', ':92', '-root', '-tree'],
                                       text=True, timeout=3)
        match = re.search(r'(0x[0-9a-f]+) "FarPane"', tree)
        return int(match[1], 16) if match else 0

    def challenge(index, window_id, identity, inbound_id):
        nonlocal began
        color = color_for(index)
        # Check absence BEFORE updating the remote desktop to exclude false
        # positives from chrome/backgrounds or coincidentally matching pixels.
        assert colored_pixels(screen.capture(), color) < 1000, 'Challenge color already present'
        changed = time.monotonic()
        remote.x.XSetWindowBackground(remote.display, pattern, color)
        remote.x.XClearWindow(remote.display, pattern)
        remote.x.XSync(remote.display, 0)
        pixels = wait(lambda: (n if (n := colored_pixels(screen.capture(), color)) > 15000 else 0),
                      'Fresh remote pixels stopped arriving', 5)
        observed = time.monotonic()
        if index == 0:
            # Duration starts at the first confirmed displayed frame, not at
            # authentication or decoder startup.
            began = observed
        assert children(gui.pid) == [worker] and window() == window_id
        state = cli({'type': 'snapshot'})
        assert len(state['inbound']) == 1 and state['inbound'][0]['authorized']
        assert state['inbound'][0]['id'] == inbound_id, 'Session reconnected during continuous test'
        folder = output / f'sample-{index:03d}'
        folder.mkdir()
        roles = {role: sample(pid, folder, role)
                 for role, pid in [('gui', gui.pid), ('host', agent.pid), ('viewer', worker)]}
        assert {role: (row['pid'], row['start_ticks']) for role, row in roles.items()} == identity
        assert roles['gui']['frame_mappings'], 'No live software frame ownership'
        record = {'index': index, 'seconds': observed - began, 'color': hex(color),
                  'fresh_pixel_observation_seconds': observed - changed,
                  'matching_remote_pixels': pixels, 'processes': roles}
        records.append(record)
        write_json(folder / 'result.json', record)
        write_json(output / 'progress.json', {'result': 'running', 'samples': len(records),
                   'continuous_seconds': record['seconds'], 'target_seconds': seconds,
                   'pids': {role: row['pid'] for role, row in roles.items()}})
        print(json.dumps({'sample': index, 'continuous_seconds': round(record['seconds'], 2),
                          'pss_kib': {role: row['pss_kib'] for role, row in roles.items()},
                          'fds': {role: row['fd_count'] for role, row in roles.items()}}), flush=True)

    try:
        window_id = wait(window, 'Main window did not appear')
        time.sleep(3)
        screen.focus(window_id)
        layout = json.loads(Path('/workspace/Linux/tests/native-lifecycle-layout.json').read_text())
        write_json(output / 'used-layout.json', layout)
        screen.capture(output / 'initial-home.png')
        assert not children(gui.pid) and not cli({'type': 'snapshot'})['inbound']
        screen.click(layout['peer'])
        screen.type('127.0.0.1:21118')
        screen.click(layout['connect'])
        workers = wait(lambda: children(gui.pid), 'Viewer worker did not start')
        assert len(workers) == 1
        worker = workers[0]
        assert Path(f'/proc/{worker}/exe').resolve() == RELEASE / 'libexec/farpane-core'
        assert b'--viewer\0' in Path(f'/proc/{worker}/cmdline').read_bytes()
        time.sleep(1)
        screen.capture(output / 'authentication.png')
        screen.click(layout['password'])
        screen.type('native-viewer-smoke')
        screen.click(layout['authenticate'])
        wait(lambda: (rows if (rows := cli({'type': 'snapshot'})['inbound'])
                      and len(rows) == 1 and rows[0]['authorized'] else None), 'Login not authorized')
        inbound_id = cli({'type': 'snapshot'})['inbound'][0]['id']
        initial_active = output / 'initial-active'
        initial_active.mkdir()
        identity = {role: (row['pid'], row['start_ticks']) for role, row in
                    ((role, sample(pid, initial_active, role)) for role, pid in
                     [('gui', gui.pid), ('host', agent.pid), ('viewer', worker)])}
        began = time.monotonic()
        # 20 seconds between challenges; the initial challenge verifies initial
        # video and the final one occurs AFTER the full requested interval.
        for index in range(seconds // 20 + 1):
            due = began + index * 20
            while time.monotonic() < due:
                assert gui.poll() is None and agent.poll() is None
                assert children(gui.pid) == [worker]
                time.sleep(min(.25, max(0, due - time.monotonic())))
            challenge(index, window_id, identity, inbound_id)
        assert records[-1]['seconds'] >= seconds
        screen.capture(output / 'final-streaming.png')
        screen.click(layout['disconnect'])
        wait(lambda: not children(gui.pid) and not Path(f'/proc/{worker}').exists(), 'Worker not reaped')
        wait(lambda: not cli({'type': 'snapshot'})['inbound'], 'Host retained inbound session')
        time.sleep(5)
        idle_folder = output / 'final-idle'
        idle_folder.mkdir()
        idle = {role: sample(pid, idle_folder, role) for role, pid in [('gui', gui.pid), ('host', agent.pid)]}
        assert not idle['gui']['frame_mappings'] and window() == window_id
        after = cli({'type': 'snapshot'})
        for key in ('local_id', 'host_enabled', 'authentication', 'permanent_password_set',
                    'temporary_password', 'server', 'sharing', 'gpu_enabled'):
            assert after[key] == initial[key], key
        assert after['revision'] == initial['revision'] + 1
        assert 'CRITICAL' not in (output / 'sustained-gui.log').read_text()
        screen.capture(output / 'final-home.png')
        screen.click(layout['close'])
        assert gui.wait(timeout=8) == 0 and agent.poll() is None
        # Record growth/ranges instead of inventing an absolute software budget
        # or equating a single 30-minute series with 24-hour leak freedom.
        warmed = [r for r in records if r['seconds'] >= 40]
        resources = {}
        for role in identity:
            baseline = warmed[0]['processes'][role]
            rows = [r['processes'][role] for r in warmed]
            resources[role] = {
                'baseline_pss_kib': baseline['pss_kib'],
                'max_pss_growth_kib': max(r['pss_kib'] - baseline['pss_kib'] for r in rows),
                'final_pss_growth_kib': rows[-1]['pss_kib'] - baseline['pss_kib'],
                'fd_min': min(r['fd_count'] for r in rows), 'fd_max': max(r['fd_count'] for r in rows),
                'thread_min': min(r['threads'] for r in rows), 'thread_max': max(r['threads'] for r in rows)}
        stable_fds = all(r['fd_min'] == r['fd_max'] for r in resources.values())
        result.update(result='pass' if stable_fds else 'resource-gate-failed',
                      thirty_minute_gate=seconds == 1800 and stable_fds,
                      continuous_seconds=records[-1]['seconds'], samples=len(records),
                      resources_after_40_seconds=resources, same_processes=identity,
                      stable_fd_counts=stable_fds, worker_reaped=True, home_frame_mappings=0,
                      host_survived_gui_exit=True, all_memory_budgets_accepted=False)
        assert stable_fds, 'FD counts did not stabilize; inspect raw samples'
    except BaseException as error:
        result.update(result='fail', error=type(error).__name__ + ': ' + str(error), samples=len(records))
        raise
    finally:
        write_json(output / 'sustained-result.json', result)
        remote.x.XDestroyWindow(remote.display, pattern)
        screen.close()
        remote.close()
