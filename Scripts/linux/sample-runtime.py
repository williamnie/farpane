#!/usr/bin/env python3
"""Read-only short CPU sample of installed FarPane processes; run as root for PSS."""
import argparse
import datetime
import json
import os
from pathlib import Path
import socket
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--seconds', type=int, default=20, choices=range(1, 61))
args = parser.parse_args()


def ipc(message):
    payload = json.dumps(message, separators=(',', ':')).encode()
    width = next(w for w in range(1, 5) if len(payload) < 1 << (8 * w - 2))
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(3)
        stream.connect('/tmp/FarPane-1000/ipc')
        stream.sendall(((len(payload) << 2) | (width - 1)).to_bytes(width, 'little') + payload)

        def read(count):
            value = b''
            while len(value) < count:
                chunk = stream.recv(count - len(value))
                if not chunk:
                    raise EOFError('FarPane IPC closed')
                value += chunk
            return value

        header = read(1)
        header += read((header[0] & 3))
        length = int.from_bytes(header, 'little') >> 2
        if length > 65536:
            raise ValueError('FarPane IPC response too large')
        return json.loads(read(length))['c']


def video_state():
    count = ipc({'t': 'VideoConnCount', 'c': None})
    state = json.loads(ipc({'t': 'Config', 'c': ['linux-gpu-status', None]})[1])
    return dict(connections=count, **state)


def snapshot():
    result = {}
    pids = subprocess.run(['pgrep', '-x', 'farpane'], capture_output=True, text=True, check=False)
    for pid in pids.stdout.split():
        proc = Path('/proc') / pid
        try:
            exe = str((proc / 'exe').resolve(strict=True))
            if not exe.startswith('/opt/farpane/releases/'):
                continue
            stat = (proc / 'stat').read_text().rsplit(')', 1)[1].split()
            argv = (proc / 'cmdline').read_bytes().split(b'\0')
            role = next((flag.decode() for flag in argv if flag in
                         (b'--service', b'--server', b'--tray', b'--cm')), 'gui')
            pss = next(int(line.split()[1]) for line in (proc / 'smaps_rollup').read_text().splitlines()
                       if line.startswith('Pss:'))
            result[pid] = dict(executable=exe, role=role, start_ticks=int(stat[19]),
                               cpu_ticks=int(stat[11]) + int(stat[12]), pss_kib=pss,
                               fd_count=len(list((proc / 'fd').iterdir())))
        except FileNotFoundError:
            continue
    return result


start = time.monotonic()
before = snapshot()
states = [video_state()]
for _ in range(args.seconds):
    time.sleep(1)
    states.append(video_state())
after = snapshot()
elapsed = time.monotonic() - start
rows = []
for pid, current in after.items():
    previous = before.get(pid)
    if previous is None or current['start_ticks'] != previous['start_ticks']:
        continue
    rows.append(dict(pid=int(pid), role=current['role'], executable=current['executable'],
                     cpu_percent=(current['cpu_ticks'] - previous['cpu_ticks']) /
                     os.sysconf('SC_CLK_TCK') / elapsed * 100,
                     pss_kib=current['pss_kib'], fd_count=current['fd_count']))
valid_video = all(s['connections'] > 0 and s['backend'] == states[0]['backend'] and
                  s['generation'] == states[0]['generation'] for s in states)
print(json.dumps(dict(utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                     elapsed_seconds=elapsed, cpu_unit='one logical core = 100%',
                     video_active_throughout=valid_video, video_states=states,
                     stable_pids=set(before) == set(after) and len(rows) == len(after),
                     total_cpu_percent=sum(row['cpu_percent'] for row in rows),
                     total_pss_kib=sum(row['pss_kib'] for row in rows), processes=rows), indent=2))
