"""Actual monitor selection and input mapping on two private XRandR monitors."""
import ctypes as C
import json
import os
from pathlib import Path
import re
import subprocess
import time

from native_host_smoke import RELEASE, cli
from native_lifecycle_smoke import Display, children, colored_pixels


class MonitorInfo(C.Structure):
    _fields_ = [('name', C.c_ulong)] + [(n, C.c_int) for n in
        ('primary', 'automatic', 'noutput', 'x', 'y', 'width', 'height', 'mwidth', 'mheight')]
    _fields_ += [('outputs', C.POINTER(C.c_ulong))]


def configure_monitors(output):
    assert Path('/.dockerenv').is_file() and os.geteuid() != 0
    display = Display(':91')
    randr = C.CDLL('libXrandr.so.2')
    randr.XRRGetMonitors.argtypes = [C.c_void_p, C.c_ulong, C.c_int, C.POINTER(C.c_int)]
    randr.XRRGetMonitors.restype = C.POINTER(MonitorInfo)
    randr.XRRFreeMonitors.argtypes = [C.POINTER(MonitorInfo)]
    randr.XRRSetMonitor.argtypes = [C.c_void_p, C.c_ulong, C.POINTER(MonitorInfo)]
    display.x.XInternAtom.argtypes = [C.c_void_p, C.c_char_p, C.c_int]
    display.x.XInternAtom.restype = C.c_ulong
    count = C.c_int()
    monitors = randr.XRRGetMonitors(display.display, display.root, 1, C.byref(count))
    assert monitors and count.value == 1 and monitors[0].noutput == 1
    outputs = (C.c_ulong * 1)(monitors[0].outputs[0])
    randr.XRRFreeMonitors(monitors)
    names = {}
    for name, x, y, width, height, primary in [('Left', 0, 0, 640, 480, 1), ('Right', 640, 80, 320, 400, 0)]:
        atom = display.x.XInternAtom(display.display, name.encode(), 0);names[atom] = name
        info = MonitorInfo(atom, primary, 0, int(bool(primary)), x, y, width, height,
                           width // 4, height // 4, outputs if primary else None)
        randr.XRRSetMonitor(display.display, display.root, C.byref(info))
    display.x.XSync(display.display, 0)
    monitors = randr.XRRGetMonitors(display.display, display.root, 1, C.byref(count))
    try:
        result = [{'name': names.get(m.name, str(m.name)), 'primary': bool(m.primary),
                   'x': m.x, 'y': m.y, 'width': m.width, 'height': m.height, 'outputs': m.noutput}
                  for m in monitors[:count.value]]
    finally:
        randr.XRRFreeMonitors(monitors);display.close()
    (output / 'randr-monitors.json').write_text(json.dumps(result, indent=2) + '\n')
    assert len(result) == 2 and [m['name'] for m in result] == ['Left', 'Right'], result
    return result


def exercise(output, start, agent, initial):
    assert Path('/.dockerenv').is_file() and os.geteuid() != 0
    env = dict(os.environ, DISPLAY=':92', GSK_RENDERER='cairo', GTK_A11Y='none',
               GTK_IM_MODULE='gtk-im-context-simple', RUST_LOG='info')
    assert not any(k.startswith('FARPANE_') and ('SMOKE_DIR' in k or 'SMOKE_EXIT' in k
                   or 'SMOKE_REPORT' in k or 'MEMORY_PROBE' in k) for k in env)
    gui = start('multidisplay-gui', [str(RELEASE / 'farpane')], env)
    screen, remote = Display(':92'), Display(':91')
    monitors = json.loads((output / 'randr-monitors.json').read_text())
    colors = [0xb04030, 0x3050b0]
    windows, records = [], []
    diagnostic = Path(os.environ['XDG_STATE_HOME']) / 'farpane/native/viewer.log'
    remote.x.XQueryPointer.argtypes = [C.c_void_p, C.c_ulong,
        C.POINTER(C.c_ulong), C.POINTER(C.c_ulong)] + [C.POINTER(C.c_int)] * 4 + [C.POINTER(C.c_uint)]
    remote.x.XQueryPointer.restype = C.c_int

    def pointer():
        root, child = C.c_ulong(), C.c_ulong()
        rx, ry, wx, wy, mask = C.c_int(), C.c_int(), C.c_int(), C.c_int(), C.c_uint()
        assert remote.x.XQueryPointer(remote.display, remote.root, C.byref(root), C.byref(child),
            C.byref(rx), C.byref(ry), C.byref(wx), C.byref(wy), C.byref(mask))
        return [rx.value, ry.value]

    def wait(predicate, message, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            statuses = {'gui': gui.poll(), 'host': agent.poll()}
            if any(code is not None for code in statuses.values()):
                (output / 'unexpected-exit.json').write_text(json.dumps(statuses) + '\n')
                screen.capture(output / 'failure.png')
                raise AssertionError(f'GUI/Host exited: {statuses}: {message}')
            value = predicate()
            if value:
                return value
            time.sleep(.1)
        screen.capture(output / 'failure.png')
        raise AssertionError(message)

    def window():
        tree = subprocess.check_output(['xwininfo', '-display', ':92', '-root', '-tree'], text=True)
        match = re.search(r'(0x[0-9a-f]+) "FarPane"', tree)
        return int(match[1], 16) if match else 0

    def bounds(capture, color):
        raw, stride = capture
        red, green, blue = color >> 16, (color >> 8) & 255, color & 255
        points = []
        for y in range(100, 720, 2):
            for x in range(0, 1020, 2):
                at = y * stride + x * 4
                b, g, r = raw[at:at + 3]
                if abs(r - red) <= 12 and abs(g - green) <= 12 and abs(b - blue) <= 12:
                    points.append((x, y))
        assert len(points) > 10000
        return [min(p[0] for p in points), min(p[1] for p in points),
                max(p[0] for p in points) + 2, max(p[1] for p in points) + 2]

    try:
        for monitor, color in zip(monitors, colors):
            w = remote.x.XCreateSimpleWindow(remote.display, remote.root, monitor['x'], monitor['y'],
                monitor['width'], monitor['height'], 0, 0, color)
            windows.append(w)
            remote.x.XMapRaised(remote.display, w)
        remote.x.XSync(remote.display, 0)
        window_id = wait(window, 'Main window did not appear')
        time.sleep(2)
        screen.focus(window_id)
        screen.click((430, 252));screen.type('127.0.0.1:21118');screen.click((824, 252))
        wait(lambda: diagnostic.exists() and 'PasswordRequired' in diagnostic.read_text(), 'No password challenge')
        screen.click((485, 233));screen.type('native-viewer-smoke');screen.click((510, 387))
        wait(lambda: '显示器目录：2 项，选择序号 0' in diagnostic.read_text(), 'Missing two-monitor catalog')
        workers = wait(lambda: children(gui.pid), 'Viewer missing')
        assert len(workers) == 1
        worker = workers[0]
        assert Path(f'/proc/{worker}/exe').resolve() == RELEASE / 'libexec/farpane-core'
        for step, index in enumerate((0, 1, 0, 1)):
            if step:
                before = len(diagnostic.read_text())
                screen.click((390, 77))
                key = 0xff54 if index else 0xff52
                screen.key(key, True);screen.key(key, False)
                screen.key(0xff0d, True);screen.key(0xff0d, False)
                wait(lambda: f'显示器目录：2 项，选择序号 {index}' in diagnostic.read_text()[before:],
                     f'Dropdown did not select monitor {index}')
            pixels = wait(lambda: (n if (n := colored_pixels(screen.capture(), colors[index])) > 40000 else 0),
                          f'Monitor {index} did not render')
            capture = screen.capture(output / f'selection-{step}-{index}.png')
            rect = bounds(capture, colors[index])
            monitor = monitors[index]
            width, height = rect[2] - rect[0], rect[3] - rect[1]
            assert abs(width / height - monitor['width'] / monitor['height']) < .02, rect
            assert children(gui.pid) == [worker], 'Display switch replaced worker'
            local = [round(rect[0] + width * .25), round(rect[1] + height * .75)]
            expected = [monitor['x'] + monitor['width'] // 4, monitor['y'] + monitor['height'] * 3 // 4]
            screen.click(local)
            def mapped_pointer():
                point = pointer()
                return point if max(abs(a-b) for a,b in zip(point, expected)) <= 3 else None
            actual = wait(mapped_pointer,
                          f'Pointer did not map into monitor {index}: expected {expected}')
            # Letterbox coordinates are outside the decoded picture. Moving or
            # clicking there must not change the remote pointer.
            assert rect[0] > 10
            outside = [rect[0] - 8, round((rect[1] + rect[3]) / 2)]
            screen.click(outside);time.sleep(.25)
            assert pointer() == actual, ('Letterbox forwarded input', pointer(), actual)
            records.append(dict(step=step, selected=index, rendered_pixels=pixels, frame_bounds=rect,
                local_click=local, expected_remote=expected, actual_remote=actual, letterbox=outside))
            (output / 'switches.json').write_text(json.dumps(records, indent=2) + '\n')
        screen.click((80, 28))
        wait(lambda: not children(gui.pid) and not Path(f'/proc/{worker}').exists(), 'Viewer was not reaped')
        wait(lambda: not cli({'type': 'snapshot'})['inbound'], 'Host retained inbound session')
        screen.click((992, 28))
        assert gui.wait(timeout=8) == 0 and agent.poll() is None
        after = cli({'type': 'snapshot'})
        assert after['local_id'] == initial['local_id'] and after['authentication'] == initial['authentication']
        result = dict(result='pass', monitors=monitors, switches=records, worker_reaped=True, host_retained=True,
            checks=['actual-two-monitor-catalog', 'dropdown-switches-0-1-0-1', 'distinct-remote-pixels',
                    'per-monitor-aspect-ratio', 'nonzero-origin-pointer-mapping', 'letterbox-input-rejected',
                    'worker-retained-during-switch', 'disconnect-reaps-worker', 'gui-close-retains-host'],
            private_x11=True, gpu=False, physical_displays=False,
            host_allocator_check=os.environ.get('FARPANE_MONITOR_ALLOCATOR_CHECK') == '1')
        (output / 'multidisplay-result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result), flush=True)
    finally:
        for w in windows:
            remote.x.XDestroyWindow(remote.display, w)
        remote.close();screen.close()


if __name__ == '__main__':
    import sys
    directory = Path(sys.argv[1]);directory.mkdir(parents=True, exist_ok=True)
    with (directory / 'xvfb.log').open('w') as log:
        server = subprocess.Popen(['Xvfb', ':91', '-screen', '0', '960x480x24', '-nolisten', 'tcp'], stdout=log, stderr=log)
        try:
            for _ in range(100):
                if Path('/tmp/.X11-unix/X91').exists():break
                assert server.poll() is None
                time.sleep(.03)
            print(json.dumps(configure_monitors(directory)), flush=True)
        finally:
            server.terminate();server.wait(timeout=3)
