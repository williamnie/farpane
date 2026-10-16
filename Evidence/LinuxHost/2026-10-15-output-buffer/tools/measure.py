#!/usr/bin/env python3
"""真实服务的进程 CPU / PSS 采样；不采集配置、凭据或画面内容。"""
import argparse
import datetime
import json
import os
import pathlib
import statistics
import time
import urllib.request

ROOT = pathlib.Path('/home/xiaobei/services/rustdesk-host-perf-20261015')
HZ = os.sysconf('SC_CLK_TCK')
HWMON = {p.joinpath('name').read_text().strip(): p for p in pathlib.Path('/sys/class/hwmon').glob('hwmon*')}
RAPL = [p for p in pathlib.Path('/sys/class/powercap').glob('intel-rapl:*') if (p / 'energy_uj').exists()]


def environment():
    ticks = [int(x) for x in pathlib.Path('/proc/stat').read_text().splitlines()[0].split()[1:9]]
    result = {'system_total_ticks': sum(ticks), 'system_busy_ticks': sum(ticks) - ticks[3] - ticks[4]}
    frequencies = []
    for path in pathlib.Path('/sys/devices/system/cpu').glob('cpu[0-9]*/cpufreq/scaling_cur_freq'):
        try:
            frequencies.append(int(path.read_text()) / 1000)
        except OSError:
            pass
    if frequencies:
        result['cpu_mhz_median'] = statistics.median(frequencies)
    for name, key, filename, scale in [('k10temp', 'cpu_temp_c', 'temp1_input', 1000),
                                       ('amdgpu', 'gpu_temp_c', 'temp1_input', 1000),
                                       ('amdgpu', 'amdgpu_power_average_w', 'power1_average', 1000000)]:
        if name in HWMON:
            try:
                result[key] = int((HWMON[name] / filename).read_text()) / scale
            except OSError:
                pass
    result['rapl'] = {}
    for path in RAPL:
        try:
            name = (path / 'name').read_text().strip()
            result['rapl'][name] = {'energy_uj': int((path / 'energy_uj').read_text()),
                                    'max_uj': int((path / 'max_energy_range_uj').read_text())}
        except OSError:
            pass
    return result


def fixture(path='/state', data=None):
    req = urllib.request.Request('http://127.0.0.1:47651' + path,
                                 data=json.dumps(data).encode() if data else None)
    return json.load(urllib.request.urlopen(req, timeout=3))


def snapshot(memory=False):
    found = {}
    for p in pathlib.Path('/proc').iterdir():
        if not p.name.isdigit():
            continue
        try:
            name = (p / 'comm').read_text().strip()
            if name not in ('rustdesk', 'hbbs', 'hbbr', 'gnome-shell', 'chrome', 'rd-perf-fixture'):
                continue
            fields = (p / 'stat').read_text().rsplit(')', 1)[1].split()
            row = {'name': name, 'cpu_s': (int(fields[11]) + int(fields[12])) / HZ}
            row['group'] = {'rustdesk': 'rustdesk', 'hbbs': 'relay', 'hbbr': 'relay',
                            'gnome-shell': 'compositor', 'chrome': 'browser', 'rd-perf-fixture': 'fixture'}[name]
            if name == 'rustdesk':
                args = (p / 'cmdline').read_bytes().split(b'\0')
                row['role'] = next((a.decode() for a in args if a in
                                    (b'--server', b'--service', b'--cm', b'--tray')), 'main')
                row['exe'] = str((p / 'exe').readlink())
                row['drm_cpu_s'] = 0
                for task in (p / 'task').iterdir():
                    try:
                        if (task / 'comm').read_text().strip() == 'drm-recv':
                            ts = (task / 'stat').read_text().rsplit(')', 1)[1].split()
                            row['drm_cpu_s'] += (int(ts[11]) + int(ts[12])) / HZ
                    except (FileNotFoundError, ProcessLookupError):
                        continue
                row['gpu_ns'] = {}
                if row['role'] == '--server':
                    clients = {}
                    for fd in (p / 'fdinfo').iterdir():
                        try:
                            info = dict(line.split(':', 1) for line in fd.read_text().splitlines() if ':' in line)
                            if 'drm-client-id' in info:
                                clients[info['drm-client-id']] = {k: int(v.split()[0]) for k, v in info.items() if k.startswith('drm-engine-')}
                        except (FileNotFoundError, ProcessLookupError):
                            continue
                    for values in clients.values():
                        for k, v in values.items():
                            row['gpu_ns'][k] = row['gpu_ns'].get(k, 0) + v
                if memory:
                    mem = {}
                    for line in (p / 'smaps_rollup').read_text().splitlines():
                        key, _, val = line.partition(':')
                        if key in ('Rss', 'Pss', 'Private_Clean', 'Private_Dirty', 'Swap'):
                            mem[key] = int(val.split()[0])
                    row['memory_kib'] = mem
            found[p.name] = row
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    return found


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--variant', choices=['A', 'B'], required=True)
    parser.add_argument('--mode', choices=['static', 'scroll', 'motion'], required=True)
    parser.add_argument('--round', type=int, required=True)
    parser.add_argument('--seconds', type=int, default=120)
    parser.add_argument('--warmup', type=int, default=15)
    args = parser.parse_args()
    state = fixture('/mode', {'mode': args.mode})
    deadline = time.monotonic() + 60
    while True:
        ready = fixture()
        if ready['ack'] == state['generation'] and ready['visible'] and ready.get('focused'):
            break
        if time.monotonic() >= deadline:
            raise SystemExit('Fixture is not visible / acknowledged')
        time.sleep(.25)
    viewport = ready.get('viewport')
    if not viewport or round(viewport['width'] * viewport['dpr']) != 2560 or round(viewport['height'] * viewport['dpr']) != 1440:
        raise SystemExit('Fixture must occupy the 2560x1440 display: ' + repr(viewport))
    time.sleep(args.warmup)
    source_first = fixture()
    first = snapshot(memory=True)
    first_env = previous_env = environment()
    servers = [v for v in first.values() if v.get('role') == '--server']
    expected = str(ROOT / 'bundles' / args.variant / 'rustdesk')
    if len(servers) != 1 or servers[0]['exe'] != expected:
        raise SystemExit('Unexpected server identity: ' + repr(servers))
    start = utc()
    t0 = prev_time = time.monotonic()
    prev = first
    rows = []
    issues = []
    for index in range(args.seconds // 2):
        time.sleep(max(0, t0 + (index + 1) * 2 - time.monotonic()))
        cur = snapshot()
        current_env = environment()
        now = time.monotonic()
        totals = {k: 0.0 for k in ['rustdesk', 'relay', 'compositor', 'browser', 'fixture', 'drm_recv', 'gpu_gfx', 'gpu_enc', 'gpu_compute']}
        for pid, row in cur.items():
            if pid not in prev:
                continue
            totals[row['group']] += (row['cpu_s'] - prev[pid]['cpu_s']) / (now - prev_time) * 100
            totals['drm_recv'] += (row.get('drm_cpu_s', 0) - prev[pid].get('drm_cpu_s', 0)) / (now - prev_time) * 100
            for engine in ('gfx', 'enc', 'compute'):
                key = 'drm-engine-' + engine
                totals['gpu_' + engine] += (row.get('gpu_ns', {}).get(key, 0) - prev[pid].get('gpu_ns', {}).get(key, 0)) / 1e9 / (now - prev_time) * 100
        extra = {k: current_env[k] for k in ['cpu_mhz_median', 'cpu_temp_c', 'gpu_temp_c', 'amdgpu_power_average_w'] if k in current_env}
        tick_delta = current_env['system_total_ticks'] - previous_env['system_total_ticks']
        extra['system_busy_pct'] = (current_env['system_busy_ticks'] - previous_env['system_busy_ticks']) / tick_delta * 100 if tick_delta else 0
        for name, reading in current_env['rapl'].items():
            if name in previous_env['rapl']:
                delta = reading['energy_uj'] - previous_env['rapl'][name]['energy_uj']
                if delta < 0:
                    delta += reading['max_uj']
                extra['rapl_' + name + '_w'] = delta / 1000000 / (now - prev_time)
        rows.append({'elapsed_s': now - t0, **totals, **extra})
        state = fixture()
        if not state['visible'] or now - state['heartbeat'] > 3:
            issues.append('fixture hidden/stale at ' + str(index))
        if not state.get('focused'):
            issues.append('fixture lost focus at ' + str(index))
        if state.get('viewport') != viewport or state['mode'] != args.mode:
            issues.append('fixture viewport/mode changed at ' + str(index))
        if {p for p, r in cur.items() if r['name'] == 'rustdesk'} != {p for p, r in first.items() if r['name'] == 'rustdesk'}:
            issues.append('RustDesk process changed at ' + str(index))
        if (index + 1) % 15 == 0:
            print(json.dumps({'variant': args.variant, 'mode': args.mode, 'round': args.round,
                              'elapsed_s': round(now-t0), 'rustdesk_cpu_mean':
                              round(statistics.mean(r['rustdesk'] for r in rows), 3)}), flush=True)
        prev, prev_time = cur, now
        previous_env = current_env
    source_fps = (state['animation_frames'] - source_first['animation_frames']) / (prev_time-t0)
    if args.mode != 'static' and source_fps < 28:
        issues.append('source animation frame rate below 28 FPS')
    result = {'parameters': vars(args), 'start_utc': start, 'end_utc': utc(), 'source_animation_fps': source_fps,
              'duration_s': prev_time - t0, 'initial': first, 'final': snapshot(memory=True),
              'samples': rows, 'issues': issues, 'viewport': viewport, 'fixture_backend': ready.get('backend', 'chrome'), 'initial_environment': first_env,
              'means': {k: statistics.mean(r[k] for r in rows if k in r) for k in rows[-1] if k != 'elapsed_s'}}
    output = ROOT / 'results' / f'{args.variant}-{args.mode}-{args.round}.json'
    output.parent.mkdir(exist_ok=True)
    with output.open('x') as f:
        json.dump(result, f, indent=2)
    print(json.dumps({'saved': str(output), 'means': result['means'], 'issues': issues}), flush=True)
    raise SystemExit(bool(issues))
