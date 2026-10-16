#!/usr/bin/env python3
"""仅启动独立 FFmpeg；只接触本次子进程，心跳丢失即停止。"""
import argparse
import datetime
import fcntl
import json
import os
import pathlib
import select
import signal
import statistics
import subprocess
import sys
import time

HZ = os.sysconf('SC_CLK_TCK')
ROOT = pathlib.Path(__file__).resolve().parent


def emit(data):
    print(json.dumps(data), flush=True)


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def snapshot(ffpid=None, memory=False):
    out = {}
    for p in pathlib.Path('/proc').iterdir():
        if not p.name.isdigit():
            continue
        try:
            name = (p / 'comm').read_text().strip()
            if name not in ('rustdesk', 'gnome-shell') and int(p.name) != ffpid:
                continue
            st = (p / 'stat').read_text().rsplit(')', 1)[1].split()
            row = {'name': name, 'cpu_s': (int(st[11]) + int(st[12])) / HZ,
                   'start_ticks': int(st[19]), 'group': 'ffmpeg' if int(p.name) == ffpid else name}
            if name == 'rustdesk':
                cmd = (p / 'cmdline').read_bytes().split(b'\0')
                row['role'] = next((x.decode() for x in cmd if x in (b'--server', b'--service', b'--cm', b'--tray')), 'main')
                row['drm_cpu_s'] = 0
                for t in (p / 'task').iterdir():
                    if (t / 'comm').read_text().strip() == 'drm-recv':
                        ts = (t / 'stat').read_text().rsplit(')', 1)[1].split()
                        row['drm_cpu_s'] += (int(ts[11]) + int(ts[12])) / HZ
            clients = {}
            for f in (p / 'fdinfo').iterdir():
                try:
                    d = dict(x.split(':', 1) for x in f.read_text().splitlines() if ':' in x)
                    if 'drm-client-id' in d:
                        clients[d['drm-client-id']] = {k: int(v.split()[0]) for k, v in d.items() if k.startswith('drm-engine-')}
                except (OSError, ValueError):
                    continue
            row['gpu_ns'] = {}
            for d in clients.values():
                for k, v in d.items():
                    row['gpu_ns'][k] = row['gpu_ns'].get(k, 0) + v
            if memory:
                row['memory_kib'] = {}
                for line in (p / 'smaps_rollup').read_text().splitlines():
                    k, _, v = line.partition(':')
                    if k in ('Rss', 'Pss', 'Private_Clean', 'Private_Dirty', 'Swap'):
                        row['memory_kib'][k] = int(v.split()[0])
            out[p.name] = row
        except (OSError, ValueError):
            continue
    return out


def delta(a, b, seconds):
    out = {'ffmpeg_cpu': 0., 'rustdesk_cpu': 0., 'server_cpu': 0., 'drm_recv_cpu': 0., 'compositor_cpu': 0.}
    for pid, row in b.items():
        if pid not in a or row['start_ticks'] != a[pid]['start_ticks']:
            continue
        cpu = (row['cpu_s'] - a[pid]['cpu_s']) / seconds * 100
        key = {'ffmpeg': 'ffmpeg_cpu', 'rustdesk': 'rustdesk_cpu', 'gnome-shell': 'compositor_cpu'}[row['group']]
        out[key] += cpu
        if row.get('role') == '--server':
            out['server_cpu'] += cpu
        out['drm_recv_cpu'] += (row.get('drm_cpu_s', 0) - a[pid].get('drm_cpu_s', 0)) / seconds * 100
        for engine, value in row['gpu_ns'].items():
            k = row['group'] + '_' + engine
            out[k] = out.get(k, 0) + (value - a[pid]['gpu_ns'].get(engine, 0)) / seconds / 1e9 * 100
    return out


def identities(s):
    return {pid: r['start_ticks'] for pid, r in s.items() if r['name'] == 'rustdesk'}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=['baseline', 'gpu', 'ram'])
    ap.add_argument('label')
    ap.add_argument('--seconds', type=int, default=60)
    args = ap.parse_args()
    experiment_lock = (ROOT / 'probe.lock').open('w')
    fcntl.flock(experiment_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if not args.label.replace('-', '').isalnum() or not 1 <= args.seconds <= 120:
        raise SystemExit('Invalid bounded experiment parameters')
    warmup = 8 if args.mode != 'baseline' else 0
    child = None
    log = None
    issues = []
    start = utc()
    initial = snapshot(memory=True)
    command = None
    samples = []
    progress_path = ROOT / (args.label + '.progress')
    try:
        if args.mode != 'baseline':
            filters = 'hwmap=derive_device=vaapi:mode=read+direct,scale_vaapi=format=nv12'
            if args.mode == 'ram':
                filters = 'hwmap=derive_device=vaapi:mode=read+direct,hwdownload,format=bgr0,format=nv12,hwupload'
            command = ['ffmpeg', '-hide_banner', '-nostdin', '-nostats', '-loglevel', 'verbose',
                       '-init_hw_device', 'vaapi=va:/dev/dri/renderD128', '-filter_hw_device', 'va',
                       '-filter_threads', '1', '-f', 'kmsgrab', '-device', '/dev/dri/card1', '-plane_id', '42',
                       '-framerate', '30', '-i', '-', '-vf', filters, '-c:v', 'h264_vaapi', '-profile:v', 'main',
                       '-rc_mode', 'CBR', '-b:v', '4000k', '-maxrate', '4000k', '-bufsize', '4000k',
                       '-g', '60', '-bf', '0', '-async_depth', '1', '-enc_time_base:v', '-1', '-fps_mode', 'passthrough',
                       '-an', '-t', str(warmup + args.seconds + 3), '-stats_period', '1',
                       '-progress', str(progress_path), '-f', 'null', '/dev/null']
            log = (ROOT / (args.label + '.log')).open('x')
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        emit({'event': 'started', 'mode': args.mode, 'label': args.label, 'utc': start,
              'child_pid': child.pid if child else None, 'command': command, 'rustdesk': identities(initial)})
        t0 = last_heartbeat = time.monotonic()
        prev = None
        first = None
        next_sample = t0 + warmup
        while True:
            now = time.monotonic()
            ready, _, _ = select.select([sys.stdin], [], [], .2)
            if ready:
                line = sys.stdin.readline()
                if not line or line.strip() == 'STOP':
                    issues.append('controller stopped or disconnected')
                    break
                last_heartbeat = time.monotonic()
            if now - last_heartbeat > 8:
                issues.append('controller heartbeat timeout')
                break
            if child and child.poll() is not None:
                issues.append('FFmpeg exited before sample window completed')
                break
            if now < next_sample:
                continue
            cur = snapshot(child.pid if child else None, memory=first is None)
            current_time = time.monotonic()
            if identities(cur) != identities(initial):
                issues.append('RustDesk identity changed')
                break
            if first is None:
                first = prev = cur
                first_time = prev_time = current_time
                sample_start_utc = utc()
            else:
                row = {'elapsed_s': current_time-first_time, **delta(prev, cur, current_time-prev_time)}
                if progress_path.exists():
                    lines = progress_path.read_text().splitlines()
                    row['ffmpeg_progress'] = dict(x.split('=', 1) for x in lines[-30:] if '=' in x)
                samples.append(row)
                emit({'event': 'sample', 'label': args.label, **row})
                prev, prev_time = cur, current_time
            next_sample = current_time + 2
            if first is not None and current_time - first_time >= args.seconds:
                break
        final = snapshot(child.pid if child and child.poll() is None else None, memory=True)
        measured = time.monotonic() - first_time if first is not None else 0
    finally:
        if child and child.poll() is None:
            if not issues:
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    issues.append('FFmpeg did not finish at its bound')
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGINT)
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
        if log:
            log.close()
    emit({'event': 'complete', 'label': args.label, 'mode': args.mode, 'start_utc': start,
          'sample_start_utc': sample_start_utc if first is not None else None, 'end_utc': utc(),
          'sample_duration_s': measured, 'command': command, 'initial': initial, 'first': first,
          'final': final, 'summary': delta(first, final, measured) if first else {},
          'exit_code': child.returncode if child else None, 'issues': issues})
    return bool(issues)


if __name__ == '__main__':
    raise SystemExit(main())
