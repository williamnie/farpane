#!/usr/bin/env python3
"""30 分钟真实连接观察；每 30 秒记录内存和 FD，结束后恢复原版。"""
import datetime
import importlib.util
import json
import pathlib
import signal
import subprocess
import time

ROOT = pathlib.Path('/home/user/services/rustdesk-host-perf-20261015')
spec = importlib.util.spec_from_file_location('measure', ROOT / 'measure.py')
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)
report = {'seconds_requested': 1800, 'samples': [], 'memory': [], 'issues': [], 'source_events': []}


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def mem_snapshot(elapsed):
    rows = {pid: row for pid, row in measure.snapshot(memory=True).items() if row['name'] == 'rustdesk'}
    for pid, row in rows.items():
        try:
            row['fd_count'] = len(list(pathlib.Path('/proc', pid, 'fd').iterdir()))
        except FileNotFoundError:
            row['fd_count'] = None
    report['memory'].append({'elapsed_s': elapsed, 'processes': rows})


def checkpoint(final=False):
    path = ROOT / 'results' / ('stability-B2.json' if final else 'stability-progress.json')
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(report, indent=2))
    temp.replace(path)


def stop(_sig, _frame):
    raise KeyboardInterrupt


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGHUP, stop)
try:
    subprocess.run(['python3', str(ROOT / 'switch_runtime.py'), 'B', '--round', '99'], check=True)
    measure.fixture('/mode', {'mode': 'static'})
    time.sleep(25)
    previous = measure.snapshot()
    expected_pids = {p for p, row in previous.items() if row['name'] == 'rustdesk'}
    servers = [r for r in previous.values() if r.get('role') == '--server']
    if len(servers) != 1 or servers[0]['exe'] != str(ROOT / 'bundles/B/rustdesk'):
        raise RuntimeError('Unexpected server before stability sample')
    report['start_utc'] = utc()
    report['server_pids'] = [p for p, row in previous.items() if row.get('role') == '--server']
    start = last_time = time.monotonic()
    mem_snapshot(0)
    phase = 0
    for i in range(360):
        time.sleep(max(0, start + (i + 1) * 5 - time.monotonic()))
        current = measure.snapshot()
        now = time.monotonic()
        cpu = sum((row['cpu_s'] - previous[p]['cpu_s']) / (now-last_time) * 100
                  for p, row in current.items() if p in previous and row['name'] == 'rustdesk')
        drm = sum((row.get('drm_cpu_s', 0) - previous[p].get('drm_cpu_s', 0)) / (now-last_time) * 100
                  for p, row in current.items() if p in previous and row['name'] == 'rustdesk')
        report['samples'].append({'elapsed_s': now-start, 'cpu': cpu, 'drm_cpu': drm})
        if {p for p, row in current.items() if row['name'] == 'rustdesk'} != expected_pids:
            report['issues'].append({'elapsed_s': now-start, 'issue': 'RustDesk process changed'})
        if (i + 1) % 6 == 0:
            mem_snapshot(now-start)
        next_phase = int((now-start) // 300)
        if next_phase != phase and next_phase < 6:
            mode = ['static', 'scroll', 'motion'][next_phase % 3]
            measure.fixture('/mode', {'mode': mode})
            report['source_events'].append({'elapsed_s': now-start, 'mode': mode})
            phase = next_phase
        if (i + 1) % 12 == 0:
            report['elapsed_s'] = now-start
            checkpoint()
            print(json.dumps({'elapsed_s': round(now-start), 'cpu_last_minute': sum(r['cpu'] for r in report['samples'][-12:])/12,
                              'issues': len(report['issues'])}), flush=True)
        previous, last_time = current, now
    report['elapsed_s'] = time.monotonic() - start
    report['status'] = 'completed'
except BaseException as exc:
    report['status'] = 'interrupted_or_failed'
    report['failure'] = repr(exc)
    raise
finally:
    report['end_utc'] = utc()
    restored = subprocess.run(['python3', str(ROOT / 'switch_runtime.py'), 'original'])
    report['restore_returncode'] = restored.returncode
    checkpoint(final=True)
    print(json.dumps({'status': report['status'], 'restore_returncode': restored.returncode,
                      'samples': len(report['samples']), 'memory_samples': len(report['memory']), 'issues': report['issues']}), flush=True)
