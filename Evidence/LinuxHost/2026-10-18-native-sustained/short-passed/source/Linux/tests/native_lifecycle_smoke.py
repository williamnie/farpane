"""External XTest driver: repeated real Home/Viewer transitions in one GUI.

No product smoke flags, internal clicks, allocator overrides or exported GTK
textures. Displays :91/:92 must be the private Xvfb pair created by the runner.
"""
import ctypes as C
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import time
import zlib
import xml.etree.ElementTree as ET

from native_host_smoke import cli, RELEASE


class XImage(C.Structure):
    _fields_ = [(n, C.c_int) for n in ('width', 'height', 'xoffset', 'format')]
    _fields_ += [('data', C.c_void_p)]
    _fields_ += [(n, C.c_int) for n in ('byte_order', 'bitmap_unit', 'bitmap_bit_order',
                                      'bitmap_pad', 'depth', 'bytes_per_line', 'bits_per_pixel')]
    _fields_ += [(n, C.c_ulong) for n in ('red_mask', 'green_mask', 'blue_mask')]


class Display:
    def __init__(self, name):
        # :93/:94 are the second isolated desktop/GUI pair in coexistence tests.
        assert name in (':91', ':92', ':93', ':94') and Path('/.dockerenv').is_file()
        self.x = C.CDLL('libX11.so.6')
        self.t = C.CDLL('libXtst.so.6')
        signatures = {
            'XOpenDisplay': ([C.c_char_p], C.c_void_p),
            'XDefaultRootWindow': ([C.c_void_p], C.c_ulong),
            'XCloseDisplay': ([C.c_void_p], C.c_int),
            'XFlush': ([C.c_void_p], C.c_int),
            'XSync': ([C.c_void_p, C.c_int], C.c_int),
            'XSetInputFocus': ([C.c_void_p, C.c_ulong, C.c_int, C.c_ulong], C.c_int),
            'XKeysymToKeycode': ([C.c_void_p, C.c_ulong], C.c_uint),
            'XGetImage': ([C.c_void_p, C.c_ulong, C.c_int, C.c_int, C.c_uint,
                          C.c_uint, C.c_ulong, C.c_int], C.POINTER(XImage)),
            'XDestroyImage': ([C.POINTER(XImage)], C.c_int),
            'XCreateSimpleWindow': ([C.c_void_p, C.c_ulong, C.c_int, C.c_int,
                                    C.c_uint, C.c_uint, C.c_uint, C.c_ulong, C.c_ulong], C.c_ulong),
            'XMapRaised': ([C.c_void_p, C.c_ulong], C.c_int),
            'XSetWindowBackground': ([C.c_void_p, C.c_ulong, C.c_ulong], C.c_int),
            'XClearWindow': ([C.c_void_p, C.c_ulong], C.c_int),
            'XDestroyWindow': ([C.c_void_p, C.c_ulong], C.c_int),
        }
        for name_, (args, result) in signatures.items():
            function = getattr(self.x, name_)
            function.argtypes, function.restype = args, result
        self.t.XTestFakeMotionEvent.argtypes = [C.c_void_p, C.c_int, C.c_int, C.c_int, C.c_ulong]
        self.t.XTestFakeButtonEvent.argtypes = [C.c_void_p, C.c_uint, C.c_int, C.c_ulong]
        self.t.XTestFakeKeyEvent.argtypes = [C.c_void_p, C.c_uint, C.c_int, C.c_ulong]
        self.display = self.x.XOpenDisplay(name.encode())
        assert self.display, name
        self.root = self.x.XDefaultRootWindow(self.display)

    def close(self):
        self.x.XCloseDisplay(self.display)

    def focus(self, window):
        self.x.XSetInputFocus(self.display, window, 2, 0)
        self.x.XFlush(self.display)

    def click(self, point):
        self.t.XTestFakeMotionEvent(self.display, -1, *point, 0)
        self.t.XTestFakeButtonEvent(self.display, 1, 1, 0)
        self.t.XTestFakeButtonEvent(self.display, 1, 0, 0)
        self.x.XFlush(self.display)
        time.sleep(.15)

    def key(self, symbol, down):
        code = self.x.XKeysymToKeycode(self.display, symbol)
        assert code
        self.t.XTestFakeKeyEvent(self.display, code, int(down), 0)
        self.x.XFlush(self.display)
        time.sleep(.012)

    def type(self, text):
        for char in text:
            shift = char == ':'
            if shift:
                self.key(0xffe1, True)
            self.key(ord(';' if shift else char), True)
            self.key(ord(';' if shift else char), False)
            if shift:
                self.key(0xffe1, False)

    def capture(self, path=None):
        image = self.x.XGetImage(self.display, self.root, 0, 0, 1020, 720, C.c_ulong(-1).value, 2)
        assert image
        try:
            info = image.contents
            assert (info.bits_per_pixel, info.byte_order, info.red_mask,
                    info.green_mask, info.blue_mask) == (32, 0, 0xff0000, 0xff00, 0xff)
            raw = C.string_at(info.data, info.bytes_per_line * info.height)
            if path:
                rows = bytearray()
                for y in range(info.height):
                    row = raw[y * info.bytes_per_line:y * info.bytes_per_line + info.width * 4]
                    rgb = bytearray(info.width * 3)
                    rgb[0::3], rgb[1::3], rgb[2::3] = row[2::4], row[1::4], row[0::4]
                    rows.append(0)
                    rows.extend(rgb)
                def chunk(kind, data):
                    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
                path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B',
                    info.width, info.height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))
            # Xvfb's unused alpha byte is not meaningful. Count actual RGB
            # pixels matching the synthetic remote rectangle within tolerance.
            return raw, info.bytes_per_line
        finally:
            self.x.XDestroyImage(image)


def colored_pixels(capture, color):
    raw, stride = capture
    red, green, blue = color >> 16, (color >> 8) & 255, color & 255
    count = 0
    for y in range(150, 690, 4):
        for x in range(40, 980, 4):
            at = y * stride + x * 4
            b, g, r = raw[at:at + 3]
            count += abs(r - red) <= 12 and abs(g - green) <= 12 and abs(b - blue) <= 12
    return count * 16


def children(pid):
    found = set()
    for task in (Path('/proc') / str(pid) / 'task').iterdir():
        try:
            found.update(int(n) for n in (task / 'children').read_text().split())
        except FileNotFoundError:
            pass
    return sorted(found)


def sample(pid, folder, role):
    proc = Path('/proc') / str(pid)
    rollup = (proc / 'smaps_rollup').read_text()
    smaps = (proc / 'smaps').read_text()
    (folder / (role + '-rollup.txt')).write_text(rollup)
    (folder / (role + '-smaps.txt')).write_text(smaps)
    values = {key: int(value) for key, value in re.findall(r'^(\w+):\s+(\d+) kB$', rollup, re.M)}
    stat = (proc / 'stat').read_text().rsplit(') ', 1)[1].split()
    fds = {}
    for fd in (proc / 'fd').iterdir():
        try:
            fds[fd.name] = str(fd.readlink())
        except FileNotFoundError:
            pass
    report = {'pid': pid, 'start_ticks': int(stat[19]), 'pss_kib': values['Pss'],
              'uss_kib': values['Private_Clean'] + values['Private_Dirty'], 'rss_kib': values['Rss'],
              'swap_pss_kib': values['SwapPss'], 'cpu_ticks': int(stat[11]) + int(stat[12]),
              'threads': int(stat[17]), 'fds': fds, 'fd_count': len(fds), 'children': children(pid),
              'frame_mappings': [line for line in smaps.splitlines()
                                 if '/memfd:farpane-frame' in line]}
    (folder / (role + '.json')).write_text(json.dumps(report, indent=2) + '\n')
    return report


def exercise(output, start, agent, initial):
    assert os.geteuid() != 0 and Path('/.dockerenv').is_file()
    rounds = int(os.environ.get('FARPANE_LIFECYCLE_ROUNDS', '20'))
    assert rounds in (1, 20)
    env = dict(os.environ, DISPLAY=':92', GSK_RENDERER='cairo', GTK_A11Y='none',
               GTK_IM_MODULE='gtk-im-context-simple', RUST_LOG='info')
    assert not any(k.startswith('FARPANE_') and ('SMOKE_DIR' in k or 'SMOKE_EXIT' in k
                    or 'SMOKE_REPORT' in k or 'MEMORY_PROBE' in k) for k in env)
    observe = os.environ.get('FARPANE_LIFECYCLE_OBJECTS') == '1'
    if observe:
        env.update(LD_PRELOAD=str(output / 'object-observer.so'), FARPANE_OBJECT_OBSERVER_DIR=str(output))
    gui = start('lifecycle-gui', [str(RELEASE / 'farpane')], env)
    screen, remote = Display(':92'), Display(':91')
    began = time.monotonic()
    records, worker_ids = [], set()
    def wait(predicate, message, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert gui.poll() is None and agent.poll() is None, 'GUI/Host exited: ' + message
            value = predicate()
            if value:
                return value
            time.sleep(.1)
        screen.capture(output / 'failure-screen.png')
        raise AssertionError(message)
    def window():
        tree = subprocess.check_output(['xwininfo', '-display', ':92', '-root', '-tree'], text=True)
        match = re.search(r'(0x[0-9a-f]+) "FarPane"', tree)
        return int(match[1], 16) if match else 0
    def object_counts(folder):
        if not observe:
            return
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(3)
            connection.connect(str(output / 'object-observer.sock'))
            data = bytearray()
            while block := connection.recv(16384):
                data.extend(block)
                assert len(data) < 262144
        result = json.loads(data)
        assert result['pid'] == gui.pid and result['overflow'] == 0
        assert result['alive'] == sum(result['types'].values())
        assert result['alive'] == result['created'] - result['destroyed']
        assert result['malloc_info_status'] == 0
        xml = result.pop('malloc_info_xml')
        (folder / 'malloc-info.xml').write_text(xml)
        tree = ET.fromstring(xml)
        assert tree.tag == 'malloc' and tree.attrib['version'] == '1'
        def total(node, tag, kind, optional=False):
            values = node.findall(f"{tag}[@type='{kind}']")
            if optional and not values:
                return 0
            assert len(values) == 1
            return int(values[0].attrib['size'])
        heaps = []
        for heap in tree.findall('heap'):
            system = total(heap, 'system', 'current')
            assert {e.attrib['type'] for e in heap.findall('total')} <= {'fast', 'rest'}
            free = total(heap, 'total', 'fast', optional=True) + total(heap, 'total', 'rest')
            assert 0 <= free <= system
            heaps.append({'index': int(heap.attrib['nr']), 'system_bytes': system,
                          'bin_free_bytes': free, 'reported_nonfree_bytes': system - free})
        system = total(tree, 'system', 'current')
        assert {e.attrib['type'] for e in tree.findall('total')} <= {'fast', 'rest', 'mmap'}
        free = total(tree, 'total', 'fast', optional=True) + total(tree, 'total', 'rest')
        assert heaps and sum(h['system_bytes'] for h in heaps) == system
        assert sum(h['bin_free_bytes'] for h in heaps) == free
        mmap = total(tree, 'total', 'mmap')
        allocation = {'glibc_version': result['glibc_version'], 'heaps': heaps,
                      'reported_arena_bin_kinds': [e.attrib['type'] for e in tree.findall('total')
                                                   if e.attrib['type'] != 'mmap'],
                      'arena_system_bytes': system, 'bin_free_bytes': free,
                      'arena_reported_nonfree_bytes': system - free, 'mmap_bytes': mmap,
                      'reported_nonfree_plus_mmap_bytes': system - free + mmap,
                      'exact_live_user_allocation_inventory': False}
        (folder / 'allocator.json').write_text(json.dumps(allocation, indent=2) + '\n')
        (folder / 'object-counts.json').write_text(json.dumps(result, indent=2) + '\n')
    pattern = remote.x.XCreateSimpleWindow(remote.display, remote.root, 80, 100, 480, 260, 0, 0, 0)
    remote.x.XMapRaised(remote.display, pattern)
    remote.x.XSync(remote.display, 0)
    try:
        window_id = wait(window, 'Main window did not appear')
        time.sleep(3)
        screen.focus(window_id)
        screen.capture(output / 'initial-home.png')
        object_counts(output)
        layout_path = Path('/workspace/Linux/tests/native-lifecycle-layout.json')
        if os.environ.get('FARPANE_LIFECYCLE_CALIBRATE') == '1':
            layout_path = output / 'layout.json'
            wait(layout_path.exists, 'Calibration layout was not supplied', 240)
        layout = json.loads(layout_path.read_text())
        (output / 'used-layout.json').write_text(json.dumps(layout, indent=2) + '\n')
        for cycle in range(rounds + 2):
            folder = output / f'cycle-{cycle:02d}'
            folder.mkdir()
            color = (0x21906a, 0x8030a0)[cycle % 2]
            remote.x.XSetWindowBackground(remote.display, pattern, color)
            remote.x.XClearWindow(remote.display, pattern)
            remote.x.XSync(remote.display, 0)
            assert not children(gui.pid) and not cli({'type': 'snapshot'})['inbound']
            screen.click(layout['peer'])
            screen.type('127.0.0.1:21118')
            screen.click(layout['connect'])
            workers = wait(lambda: children(gui.pid), 'Viewer worker did not start')
            assert len(workers) == 1 and workers[0] not in worker_ids
            worker = workers[0]
            assert (Path('/proc') / str(worker) / 'exe').resolve() == RELEASE / 'libexec/farpane-core'
            worker_ids.add(worker)
            time.sleep(1)
            screen.capture(folder / 'authentication.png')
            if cycle == 0 and os.environ.get('FARPANE_LIFECYCLE_CALIBRATE') == '1':
                auth = output / 'auth-layout.json'
                wait(auth.exists, 'Calibration password layout was not supplied', 240)
                layout.update(json.loads(auth.read_text()))
                (output / 'used-layout.json').write_text(json.dumps(layout, indent=2) + '\n')
            screen.click(layout['password'])
            screen.type('native-viewer-smoke')
            screen.click(layout['authenticate'])
            pixels = wait(lambda: (n if (n := colored_pixels(screen.capture(), color)) > 15000 else 0),
                          'New remote color was not actually displayed', 25)
            inbound = cli({'type': 'snapshot'})['inbound']
            assert len(inbound) == 1 and inbound[0]['authorized']
            screen.capture(folder / 'streaming.png')
            assert children(gui.pid) == [worker]
            active = {role: sample(pid, folder, role) for role, pid in
                      [('active-gui', gui.pid), ('active-host', agent.pid), ('active-viewer', worker)]}
            assert active['active-gui']['frame_mappings'], 'Missing live software frame ownership evidence'
            screen.click(layout['disconnect'])
            wait(lambda: not children(gui.pid) and not Path(f'/proc/{worker}').exists(), 'Worker not reaped')
            wait(lambda: not cli({'type': 'snapshot'})['inbound'], 'Host retained inbound session')
            # Product Home schedules its existing reclamation after 2 seconds.
            # Use the same 5 second idle interval for warmup and measured cycles.
            time.sleep(5)
            assert window() == window_id and not children(gui.pid)
            idle = {role: sample(pid, folder, role) for role, pid in [('gui', gui.pid), ('host', agent.pid)]}
            object_counts(folder)
            assert not idle['gui']['frame_mappings'], 'Home retained the software frame mapping'
            assert colored_pixels(screen.capture(folder / 'home.png'), color) < 1000, 'Remote pixels remained on Home'
            after = cli({'type': 'snapshot'})
            for key in ('local_id', 'host_enabled', 'authentication', 'permanent_password_set',
                        'temporary_password', 'server', 'sharing', 'gpu_enabled'):
                assert after[key] == initial[key], key
            assert after['revision'] == initial['revision'] + cycle + 1
            record = {'cycle': cycle, 'warmup': cycle < 2, 'seconds': time.monotonic() - began,
                      'worker_pid': worker, 'worker_reaped': True, 'displayed_color': hex(color),
                      'matching_remote_pixels': pixels, 'active': active, 'idle': idle}
            records.append(record)
            (folder / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
            print(json.dumps({'cycle': cycle, 'warmup': cycle < 2, 'gui_pss_kib': idle['gui']['pss_kib'],
                              'host_pss_kib': idle['host']['pss_kib'], 'gui_fd': idle['gui']['fd_count'],
                              'host_fd': idle['host']['fd_count'], 'worker_reaped': True}), flush=True)
        baseline, measured = records[1]['idle'], records[2:]
        growth = {role: max(r['idle'][role]['pss_kib'] - baseline[role]['pss_kib'] for r in measured)
                  for role in ('gui', 'host')}
        combined = max(sum(r['idle'][role]['pss_kib'] - baseline[role]['pss_kib']
                           for role in ('gui', 'host')) for r in measured)
        stable_fds = all(r['idle'][role]['fd_count'] == baseline[role]['fd_count']
                         for r in measured for role in ('gui', 'host'))
        result = {'result': 'pass' if combined <= 10240 and max(growth.values()) <= 10240
                  and stable_fds else 'resource-gate-failed',
                  'rounds': rounds, 'warmup_rounds': 2, 'same_gui_pid': gui.pid, 'same_host_pid': agent.pid,
                  'unique_workers_reaped': len(worker_ids), 'max_idle_growth_kib': growth,
                  'max_combined_idle_growth_kib': combined, 'stable_idle_fd_counts': stable_fds,
                  'gpu_tested': False, 'real_desktop_tested': False, 'product_test_hooks': False,
                  'gobject_observer_enabled': observe, 'memory_budget_accepted_with_observer': False,
                  'records': records}
        assert 'CRITICAL' not in (output / 'lifecycle-gui.log').read_text()
        screen.click(layout['close'])
        assert gui.wait(timeout=8) == 0 and agent.poll() is None
        assert not cli({'type': 'snapshot'})['inbound']
        result.update(gui_window_closed=True, host_survived_gui_exit=True)
        (output / 'lifecycle-result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({k: v for k, v in result.items() if k != 'records'}), flush=True)
        assert result['result'] == 'pass', 'Repeated connection resource gate failed; inspect recorded samples'
    finally:
        remote.x.XDestroyWindow(remote.display, pattern)
        screen.close()
        remote.close()
