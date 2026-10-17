#!/usr/bin/env python3
"""Read-only /proc sampling of one immutable native FarPane release.

Run as root to include the supervisor's proportional memory and DRM counters.
No service, configuration, display or GPU commands are executed. Process
arguments and user data are not copied. CPU 100% denotes one logical CPU.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import time


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def processes(release):
    result = []
    permitted = {release / 'farpane', release / 'libexec/farpane-core'}
    for proc in Path('/proc').iterdir():
        if not proc.name.isdecimal():
            continue
        try:
            executable = (proc / 'exe').resolve(strict=True)
            if executable not in permitted:
                continue
            arguments = (proc / 'cmdline').read_bytes().split(b'\0')
            role = ('gui' if executable.name == 'farpane' else
                    next((x[2:] for x in ('--service', '--server', '--viewer')
                          if x.encode() in arguments), 'core'))
            stat = (proc / 'stat').read_text().rsplit(')', 1)[1].split()
            memory = {}
            for line in (proc / 'smaps_rollup').read_text().splitlines():
                fields = line.split()
                if fields[0] in ('Rss:', 'Pss:', 'SwapPss:'):
                    memory[fields[0].rstrip(':').lower() + '_kib'] = int(fields[1])
            descriptors = list((proc / 'fd').iterdir())
            drm = {}
            for descriptor in descriptors:
                try:
                    target = os.readlink(descriptor)
                    if not target.startswith('/dev/dri/renderD'):
                        continue
                    fields = {}
                    for line in (proc / 'fdinfo' / descriptor.name).read_text().splitlines():
                        key, _, value = line.partition(':')
                        if key.startswith('drm-'):
                            fields[key] = value.strip()
                    drm[(target, fields.get('drm-client-id', descriptor.name))] = {
                        'node': target, **fields}
                except (OSError, ValueError):
                    continue
            result.append({'pid': int(proc.name), 'uid': proc.stat().st_uid,
                           'role': role, 'start_ticks': int(stat[19]),
                           'cpu_ticks': int(stat[11]) + int(stat[12]),
                           'fd_count': len(descriptors), **memory,
                           'drm_clients': list(drm.values())})
        except (OSError, ValueError, IndexError):
            # A process may exit between reads; omit partial observations.
            continue
    return sorted(result, key=lambda p: p['pid'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--release', type=Path, default=Path('/opt/farpane/current'))
    parser.add_argument('--seconds', type=int, default=30)
    parser.add_argument('--interval', type=int, default=5)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('Root read access is required for all process memory counters')
    if not 1 <= args.seconds <= 120 or not 1 <= args.interval <= args.seconds:
        parser.error('Use 1–120 seconds and an interval within that duration')
    release = args.release.resolve(strict=True)
    output = args.output.resolve()
    build = Path(__file__).resolve().parents[2] / 'Build/Linux'
    if not output.is_relative_to(build.resolve()) or output.exists():
        parser.error('Output must be a new file under Build/Linux')
    hz = os.sysconf('SC_CLK_TCK')
    samples = []
    started = time.monotonic()
    while True:
        now = time.monotonic()
        samples.append({'utc': timestamp(), 'elapsed_s': now - started,
                        'processes': processes(release)})
        remaining = args.seconds - (time.monotonic() - started)
        if remaining <= 0:
            break
        time.sleep(min(args.interval, remaining))
    first = {(p['pid'], p['start_ticks']): p for p in samples[0]['processes']}
    elapsed = samples[-1]['elapsed_s'] - samples[0]['elapsed_s']
    totals = []
    for process in samples[-1]['processes']:
        key = process['pid'], process['start_ticks']
        if key not in first:
            continue
        observed = [p for s in samples for p in s['processes']
                    if (p['pid'], p['start_ticks']) == key]
        totals.append({'pid': process['pid'], 'role': process['role'],
                       'cpu_percent_one_core':
                       100 * (process['cpu_ticks'] - first[key]['cpu_ticks']) / hz / elapsed,
                       'pss_mib_min': min(p['pss_kib'] for p in observed) / 1024,
                       'pss_mib_max': max(p['pss_kib'] for p in observed) / 1024,
                       'fd_min': min(p['fd_count'] for p in observed),
                       'fd_max': max(p['fd_count'] for p in observed)})
    result = {'schema': 1, 'release': str(release), 'clock_ticks_per_second': hz,
              'duration_s': elapsed, 'cpu_basis': '100 percent = one logical CPU',
              'scope': 'passive live desktop sample; uncontrolled workload; no formal A/B',
              'process_summary': totals,
              'total_pss_mib_min': min(sum(p['pss_kib'] for p in s['processes'])
                                       for s in samples) / 1024,
              'total_pss_mib_max': max(sum(p['pss_kib'] for p in s['processes'])
                                       for s in samples) / 1024,
              'samples': samples}
    with output.open('x') as stream:
        stream.write(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'samples'}, indent=2))


if __name__ == '__main__':
    main()
