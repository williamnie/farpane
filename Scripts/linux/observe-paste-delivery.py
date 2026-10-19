#!/usr/bin/env python3
"""Bounded, passive trace of where a committed-text paste stops on GNOME.

On a GNOME Wayland host the core writes committed text to the Xwayland
CLIPBOARD and presses Shift+Insert. Native Wayland applications read that
selection through Mutter's X11 bridge, X11 applications read it directly.
This records, from the Xwayland display only:

- CLIPBOARD/PRIMARY owner changes (XFixes), labelled by owning process;
- ConvertSelection requests (RECORD): requesting process and target type;
- Shift/Control/Insert key events Xwayland delivers (X11 focus only), and
  the V key only while Control is held;
- fixed stage records of the Host core log (commit id, char count, timing).

Selection contents, other keys and other log text never leave this process.
Nothing is written to the display, clipboard, input devices or services.
"""

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import secrets
import select
import socket
import struct
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
MAX_SECONDS = 600
SELECTIONS = ('CLIPBOARD', 'PRIMARY')
# Evdev code + 8; the uinput keyboard and the Mac keyboard share this layout.
KEYCODES = {37: 'Control_L', 105: 'Control_R', 50: 'Shift_L', 62: 'Shift_R', 118: 'Insert'}
KEYCODE_V = 55
COMM = re.compile(r'^[A-Za-z0-9._-]{1,15}$')
ATOM = re.compile(r'^[\x21-\x7e]{1,64}$')

PREFIX = re.compile(r'^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+ [+-]\d\d:\d\d)\]\s+\w+\s+\[[^\]]*\]\s')
REPEAT = r'(?: \(x(\d+)\))?$'
STAGES = (
    ('commit', re.compile(r'Native committed text #(\d+): chars=(\d+) ascii=(true|false)'
                          r' released_modifiers=(0b[01]{3})' + REPEAT)),
    ('commit_dropped', re.compile(r'Native committed text #(\d+) dropped: ')),
    ('clipboard_written', re.compile(r'Native paste clipboard written in (\d+) ms' + REPEAT)),
    ('clipboard_set_failed', re.compile(r'set_clipboard_content: failed')),
    ('paste_preparing', re.compile(r'Native committed text: clipboard ready; preparing paste$')),
    ('paste_queued', re.compile(r'Native committed text: paste key sequence queued$')),
    ('paste_key_failed', re.compile(r'input_text_via_clipboard_server: failed to press (Insert|Shift)')),
    ('restore', re.compile(r'Native committed text: clipboard restored=(true|false)$')),
    ('restore_failed', re.compile(r'Native committed text: clipboard restore (failed|unavailable): ')),
    ('ibus_committed', re.compile(r'Native committed text: IBus commit sent$')),
    ('ibus_no_client', re.compile(r'Native committed text: no IBus client focused; using paste$')),
    ('ibus_unavailable', re.compile(r'Native committed text: IBus unavailable; using paste: ')),
)


def classify(line):
    """Returns a fixed stage record for a whitelisted log line, else None."""
    match = PREFIX.match(line)
    if not match:
        return None
    message = line[match.end():].rstrip('\r\n')
    for stage, rule in STAGES:
        found = rule.match(message)
        if not found:
            continue
        wall = datetime.fromisoformat(match.group(1)).timestamp()
        record = {'source': 'core_log', 'stage': stage, 'log_wall': round(wall, 6)}
        groups = found.groups()
        if stage == 'commit':
            record.update(commit=int(groups[0]), chars=int(groups[1]),
                          ascii=groups[2] == 'true', released=groups[3])
            if groups[4]:
                record['repeat'] = int(groups[4])
        elif stage == 'commit_dropped':
            record['commit'] = int(groups[0])
        elif stage == 'clipboard_written':
            record['ms'] = int(groups[0])
            if groups[1]:
                record['repeat'] = int(groups[1])
        elif stage in ('paste_key_failed', 'restore', 'restore_failed'):
            record['detail'] = groups[0]
        return record
    return None


class LogTail:
    def __init__(self, path):
        self.path = path
        self.handle = None
        self.inode = None
        self.pending = ''
        self.open(at_end=True)

    def open(self, at_end):
        try:
            handle = open(self.path, encoding='utf-8', errors='replace')
        except OSError:
            return
        if self.handle:
            self.handle.close()
        self.handle = handle
        self.inode = os.fstat(handle.fileno()).st_ino
        self.pending = ''
        if at_end:
            handle.seek(0, os.SEEK_END)

    def poll(self):
        try:
            current = os.stat(self.path)
        except OSError:
            current = None
        if self.handle is None or (current and current.st_ino != self.inode):
            self.open(at_end=False)
        elif current and current.st_size < self.handle.tell():
            self.open(at_end=False)
        if self.handle is None:
            return []
        records = []
        self.pending += self.handle.read()
        *lines, self.pending = self.pending.split('\n')
        for line in lines:
            record = classify(line)
            if record:
                records.append(record)
        return records


def xauth_cookie(path, display):
    """MIT-MAGIC-COOKIE-1 for a local display from an Xauthority file."""
    data = Path(path).read_bytes()
    offset = 0

    def field():
        nonlocal offset
        (size,) = struct.unpack_from('>H', data, offset)
        value = data[offset + 2:offset + 2 + size]
        offset += 2 + size
        return value

    fallback = None
    while offset + 2 <= len(data):
        offset += 2  # family
        field()      # address
        number, name, cookie = field(), field(), field()
        if name != b'MIT-MAGIC-COOKIE-1':
            continue
        if number == str(display).encode():
            return cookie
        fallback = fallback or cookie
    return fallback


def pad(size):
    return (4 - size % 4) % 4


class XConnection:
    def __init__(self, display, cookie):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(f'/tmp/.X11-unix/X{display}')
        name = b'MIT-MAGIC-COOKIE-1' if cookie else b''
        cookie = cookie or b''
        self.sock.sendall(struct.pack('<BxHHHHxx', ord('l'), 11, 0, len(name), len(cookie))
                          + name + b'\0' * pad(len(name)) + cookie + b'\0' * pad(len(cookie)))
        head = self.read(8)
        if head[0] != 1:
            raise RuntimeError('X connection refused')
        (extra,) = struct.unpack_from('<H', head, 6)
        body = self.read(extra * 4)
        self.id_base, self.id_mask = struct.unpack_from('<II', body, 4)
        vendor, formats = struct.unpack_from('<H', body, 16)[0], body[21]
        screen = 32 + vendor + pad(vendor) + formats * 8
        (self.root,) = struct.unpack_from('<I', body, screen)
        self.sequence = 0
        self.next_id = 0
        self.events = []

    def read(self, size):
        data = b''
        while len(data) < size:
            chunk = self.sock.recv(size - len(data))
            if not chunk:
                raise ConnectionError('X connection closed')
            data += chunk
        return data

    def allocate(self):
        self.next_id += 1
        return self.id_base | self.next_id

    def send(self, opcode, data1, body):
        size = 4 + len(body)
        self.sock.sendall(struct.pack('<BBH', opcode, data1, (size + pad(size)) // 4)
                          + body + b'\0' * pad(size))
        self.sequence = (self.sequence + 1) & 0xffff
        return self.sequence

    def packet(self):
        head = self.read(32)
        if head[0] == 1 or head[0] == 35:
            (extra,) = struct.unpack_from('<I', head, 4)
            return head + self.read(extra * 4)
        return head

    def request(self, opcode, data1, body):
        sequence = self.send(opcode, data1, body)
        while True:
            packet = self.packet()
            (got,) = struct.unpack_from('<H', packet, 2)
            if packet[0] == 0 and got == sequence:
                raise RuntimeError(f'X error {packet[1]} for opcode {opcode}')
            if packet[0] == 1 and got == sequence:
                return packet
            if packet[0] > 1:
                self.events.append(packet)

    def intern(self, name):
        raw = name.encode()
        reply = self.request(16, 0, struct.pack('<Hxx', len(raw)) + raw)
        return struct.unpack_from('<I', reply, 8)[0]

    def atom_name(self, atom):
        reply = self.request(17, 0, struct.pack('<I', atom))
        (size,) = struct.unpack_from('<H', reply, 8)
        return reply[32:32 + size].decode('latin-1')

    def extension(self, name):
        raw = name.encode()
        reply = self.request(98, 0, struct.pack('<Hxx', len(raw)) + raw)
        if not reply[8]:
            raise RuntimeError(f'X extension {name} unavailable')
        return reply[9], reply[10]


class Labels:
    """Maps an X client to a fixed process label; never exports window titles."""

    def __init__(self, conn, xres):
        self.conn = conn
        self.xres = xres
        self.cache = {}

    def client(self, base):
        base &= ~self.conn.id_mask
        if base not in self.cache:
            self.cache[base] = self.lookup(base)
        return self.cache[base]

    def lookup(self, base):
        try:
            reply = self.conn.request(self.xres, 4, struct.pack('<III', 1, base, 2))
            (count,) = struct.unpack_from('<I', reply, 8)
            offset = 32
            for _ in range(count):
                _, mask, size = struct.unpack_from('<III', reply, offset)
                offset += 12
                if mask == 2 and size == 4:
                    return label_pid(struct.unpack_from('<I', reply, offset)[0])
                offset += size
        except (RuntimeError, struct.error):
            pass
        return 'unknown'


def label_pid(pid):
    try:
        exe = os.readlink(f'/proc/{pid}/exe')
    except OSError:
        exe = ''
    if exe.startswith('/opt/farpane/'):
        return 'farpane-core'
    if exe.endswith('/gnome-shell'):
        return 'gnome-shell (Wayland bridge)'
    try:
        comm = Path(f'/proc/{pid}/comm').read_text().strip()
    except OSError:
        return 'unknown'
    return comm if COMM.match(comm) else 'unknown'


RECORD_RANGE = struct.Struct('<BBBBBBHHBBHHBBBBBBBB')


def record_context(conn, record_major):
    conn.request(record_major, 0, struct.pack('<HH', 1, 13))
    context = conn.allocate()
    # Core ConvertSelection requests and KeyPress/KeyRelease device events.
    selection = RECORD_RANGE.pack(24, 24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    keys = RECORD_RANGE.pack(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 0, 0, 0, 0)
    conn.send(record_major, 1, struct.pack('<IBxxxII', context, 0, 1, 2)
              + struct.pack('<I', 3) + selection + keys)
    conn.request(43, 0, b'')  # GetInputFocus: surfaces a CreateContext error
    return context


def parse_record(packet):
    """Yields (kind, id_base, fields) from one RECORD EnableContext reply."""
    category, swapped = packet[1], packet[9]
    (id_base,) = struct.unpack_from('<I', packet, 12)
    data = packet[32:]
    if category == 1 and len(data) >= 24 and data[0] == 24:
        order = '>' if swapped else '<'
        _, selection, target = struct.unpack_from(order + 'III', data, 4)
        yield 'convert', id_base, {'selection': selection, 'target': target}
    elif category == 0:
        for offset in range(0, len(data) - 31, 32):
            kind, keycode = data[offset], data[offset + 1]
            if kind in (2, 3):
                yield 'key', id_base, {'down': kind == 2, 'keycode': keycode}


class Trace:
    def __init__(self, out):
        self.out = out
        self.start = time.monotonic()
        self.wall = time.time()
        self.count = 0

    def emit(self, record):
        record['t_ms'] = round((time.monotonic() - self.start) * 1000, 2)
        record['wall'] = round(time.time(), 6)
        self.count += 1
        self.out.write(json.dumps(record, ensure_ascii=False) + '\n')
        self.out.flush()


ANCHORS = {'paste_preparing': 'paste', 'ibus_committed': 'ibus'}


def summarize(records):
    """Groups observations around each paste or IBus commit the core made.

    An INFO commit record is throttled, so the per-delivery DEBUG record anchors
    a group; X records from 200 ms before it until the next group belong to it.
    """
    lead = 0.2
    groups, commit = [], None
    for record in records:
        if record.get('stage') == 'commit':
            commit = record
        elif record.get('stage') in ANCHORS:
            groups.append({'at': record['log_wall'], 'via': ANCHORS[record['stage']],
                           'commit': commit and commit['commit'],
                           'chars': commit and commit['chars'], 'ascii': commit and commit['ascii'],
                           'stages': [], 'owners': [], 'reads': [], 'keys': []})
    for record in records:
        if record['source'] == 'observer' or record.get('stage') == 'commit' or record.get('stage') in ANCHORS:
            continue
        at = record.get('log_wall', record['wall'])
        group = None
        for candidate in groups:
            if candidate['at'] - lead <= at:
                group = candidate
        if group is None:
            continue
        offset = f"{round((at - group['at']) * 1000, 1)}ms"
        if record['source'] == 'core_log':
            group['stages'].append(f"{record['stage']}@{offset}")
        elif record['source'] == 'owner':
            group['owners'].append(f"{record['selection']}:{record['owner']}@{offset}")
        elif record['source'] == 'convert':
            group['reads'].append(
                f"{record['selection']}:{record['requestor']}:{record['target']}@{offset}")
        elif record['source'] == 'key':
            group['keys'].append(f"{record['key']}{'↓' if record['down'] else '↑'}@{offset}")
    return groups


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--seconds', type=int, default=180)
    parser.add_argument('--display', default=os.environ.get('DISPLAY', ':0'))
    parser.add_argument('--xauthority', default=os.environ.get('XAUTHORITY'))
    parser.add_argument('--log', type=Path,
        default=Path.home() / '.local/share/logs/FarPane/server/farpane-core_rCURRENT.log')
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if not 1 <= args.seconds <= MAX_SECONDS:
        parser.error(f'--seconds must be within 1..{MAX_SECONDS}')
    display = int(args.display.lstrip(':').split('.')[0])
    cookie = xauth_cookie(args.xauthority, display) if args.xauthority else None

    out_dir = args.out or ROOT / 'Build/Linux/native-paste-delivery' / f'capture-{secrets.token_hex(4)}'
    out_dir.mkdir(parents=True, exist_ok=True)

    control = XConnection(display, cookie)
    data = XConnection(display, cookie)
    xfixes, xfixes_event = control.extension('XFIXES')
    record_major, _ = control.extension('RECORD')
    xres, _ = control.extension('X-Resource')
    control.request(xfixes, 0, struct.pack('<II', 5, 0))
    control.request(xres, 0, struct.pack('<BB', 1, 2))
    labels = Labels(control, xres)
    atoms = {control.intern(name): name for name in SELECTIONS}
    for atom in atoms:
        control.send(xfixes, 2, struct.pack('<III', control.root, atom, 7))
    context = record_context(control, record_major)
    data.send(record_major, 5, struct.pack('<I', context))
    targets = {}

    def target_name(atom):
        if atom not in targets:
            name = control.atom_name(atom)
            targets[atom] = name if ATOM.match(name) else f'atom:{atom}'
        return targets[atom]

    tail = LogTail(args.log)
    records = []
    ctrl_down = set()
    events_path = out_dir / 'events.jsonl'
    with open(events_path, 'w', encoding='utf-8') as out:
        trace = Trace(out)

        def keep(record):
            trace.emit(record)
            records.append(record)

        keep({'source': 'observer', 'stage': 'started', 'display': display,
              'log_found': tail.handle is not None})
        print(f'Observing for {args.seconds}s; type now. Output: {out_dir}', flush=True)
        deadline = time.monotonic() + args.seconds
        while time.monotonic() < deadline:
            ready, _, _ = select.select([control.sock, data.sock], [], [], 0.05)
            if data.sock in ready:
                packet = data.packet()
                if packet[0] == 1:
                    for kind, base, fields in parse_record(packet):
                        if kind == 'convert' and fields['selection'] in atoms:
                            keep({'source': 'convert', 'selection': atoms[fields['selection']],
                                  'requestor': labels.client(base),
                                  'target': target_name(fields['target'])})
                        elif kind == 'key':
                            code = fields['keycode']
                            if code in (37, 105):
                                (ctrl_down.add if fields['down'] else ctrl_down.discard)(code)
                            name = KEYCODES.get(code)
                            if name is None and code == KEYCODE_V and ctrl_down:
                                name = 'V(with Control)'
                            if name:
                                keep({'source': 'key', 'key': name, 'down': fields['down']})
            if control.sock in ready:
                control.events.append(control.packet())
            while control.events:
                event = control.events.pop(0)
                if event[0] == xfixes_event:
                    owner, selection = struct.unpack_from('<II', event, 8)
                    keep({'source': 'owner', 'selection': atoms.get(selection, 'other'),
                          'owner': labels.client(owner) if owner else 'none'})
            for record in tail.poll():
                keep(record)
        keep({'source': 'observer', 'stage': 'finished'})

    pastes = summarize(records)
    summary = {'schema': 'farpane-paste-delivery', 'schema_version': 1,
               'seconds': args.seconds, 'records': len(records), 'pastes': pastes}
    (out_dir / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=1) + '\n')
    for paste in pastes:
        print(f"paste after commit #{paste['commit']} chars={paste['chars']} ascii={paste['ascii']}")
        for key in ('stages', 'owners', 'reads', 'keys'):
            if paste[key]:
                print(f'  {key}: ' + ', '.join(paste[key]))
    print(f'{len(records)} records, {len(pastes)} pastes -> {out_dir}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
