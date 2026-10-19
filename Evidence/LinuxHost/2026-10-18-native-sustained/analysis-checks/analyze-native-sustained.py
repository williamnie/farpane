#!/usr/bin/env python3
"""Validate a completed continuous-session series and summarize its raw samples.

This accepts only terminal, successful runs. Short fixture qualification stays
distinct from the 30-minute software gate; neither implies full GUI acceptance.
"""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import re

ROLES = ('gui', 'host', 'viewer')
ROOT = Path(__file__).resolve().parents[2]


def read(path):
    return json.loads(path.read_text())


def validate(records, result, seconds):
    if (result.get('result') != 'pass' or seconds not in (60, 1800)
            or result.get('requested_seconds') != seconds or len(records) != 91
            or result.get('samples') != 91):
        raise ValueError('Requires a completed successful full-palette run with 91 samples')
    if (result.get('thirty_minute_gate') is not (seconds == 1800)
            or result.get('gpu_tested') is not False
            or result.get('root_service_tested') is not False
            or result.get('real_desktop_tested') is not False
            or result.get('product_test_hooks') is not False):
        raise ValueError('Unexpected gate or scope declaration')
    if not all(result.get(k) is True for k in ('stable_fd_counts', 'worker_reaped',
                                              'host_survived_gui_exit')):
        raise ValueError('Session teardown or descriptor check did not pass')
    if result.get('home_frame_mappings') != 0:
        raise ValueError('Home still owns a software frame')
    identities = result['same_processes']
    seen_colors = set()
    previous = None
    for index, row in enumerate(records):
        if not all(math.isfinite(row[k]) for k in ('seconds', 'fresh_pixel_observation_seconds')):
            raise ValueError('Non-finite timing sample')
        if row['index'] != index or row['color'] in seen_colors:
            raise ValueError('Missing/repeated sample or color')
        seen_colors.add(row['color'])
        if row['seconds'] < index * seconds / 90:
            raise ValueError('Challenge observed before its scheduled time')
        if (not 0 <= row['fresh_pixel_observation_seconds'] <= 5
                or row['matching_remote_pixels'] <= 15000):
            raise ValueError('Fresh frame observation requirement not met')
        if previous and row['seconds'] <= previous['seconds']:
            raise ValueError('Non-monotonic sample times')
        for role in ROLES:
            process = row['processes'][role]
            if [process['pid'], process['start_ticks']] != identities[role]:
                raise ValueError('Process identity changed')
            if process['fd_count'] != len(process['fds']):
                raise ValueError('Descriptor summary does not match raw entries')
            if process['swap_pss_kib'] < 0 or process['pss_kib'] < 0:
                raise ValueError('Invalid memory reading')
            if previous and process['cpu_ticks'] < previous['processes'][role]['cpu_ticks']:
                raise ValueError('CPU counter moved backwards')
        if not row['processes']['gui']['frame_mappings']:
            raise ValueError('No active frame ownership')
        if row['processes']['gui']['children'] != [identities['viewer'][0]]:
            raise ValueError('Unexpected GUI worker ownership')
        previous = row
    if records[-1]['seconds'] < seconds or records[-1]['seconds'] != result['continuous_seconds']:
        raise ValueError('Requested continuous duration was not reached')


def summarize(records, result, ticks):
    warmed = [r for r in records if r['seconds'] >= 40]
    first, last = warmed[0], warmed[-1]
    # The last five minutes for a long run; the last ten seconds for a short
    # fixture. Report the actual sampled span rather than assume exact timing.
    tail = [r for r in warmed if r['seconds'] >= last['seconds'] -
            (300 if result['requested_seconds'] == 1800 else 10)]
    summary = {k: v for k, v in result.items() if k != 'resources_after_40_seconds'}
    summary.update(clock_ticks_per_second=ticks,
                   cpu_scope='single-core percentage; counters sampled consecutively per cycle',
                   sampled_roles=list(ROLES), full_product_memory_accepted=False,
                   persistent_growth_ruled_out=False, twenty_four_hours_tested=False,
                   network_latency_measured=False, resources={})
    for role in ROLES:
        base = first['processes'][role]
        final = last['processes'][role]
        samples = [r['processes'][role] for r in warmed]
        tail_delta = final['pss_kib'] - tail[0]['processes'][role]['pss_kib']
        summary['resources'][role] = {
            'baseline_seconds': first['seconds'], 'baseline_pss_kib': base['pss_kib'],
            'final_pss_kib': final['pss_kib'], 'final_uss_kib': final['uss_kib'],
            'max_pss_growth_kib': max(s['pss_kib'] - base['pss_kib'] for s in samples),
            'final_pss_growth_kib': final['pss_kib'] - base['pss_kib'],
            'tail_span_seconds': last['seconds'] - tail[0]['seconds'],
            'tail_pss_growth_kib': tail_delta,
            'cpu_single_core_percent': 100 * (final['cpu_ticks'] - base['cpu_ticks']) /
                                       ticks / (last['seconds'] - first['seconds']),
            'fd_min': min(s['fd_count'] for s in samples), 'fd_max': max(s['fd_count'] for s in samples),
            'threads_min': min(s['threads'] for s in samples), 'threads_max': max(s['threads'] for s in samples),
            'max_swap_pss_kib': max(s['swap_pss_kib'] for s in samples),
            'max_frame_mappings': max(len(s['frame_mappings']) for s in samples)}
        if summary['resources'][role]['fd_min'] != summary['resources'][role]['fd_max']:
            raise ValueError('Recorded FD stability claim does not match samples')
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path, help='Outer run directory containing inputs.json and exit.json')
    parser.add_argument('--clock-ticks', required=True, type=int,
                        help='CLK_TCK from the host kernel used by this container (getconf CLK_TCK)')
    parser.add_argument('--plot', action='store_true')
    args = parser.parse_args()
    if args.clock_ticks <= 0:
        parser.error('clock-ticks must be positive')
    run = args.run.resolve(strict=True)
    inputs = read(run / 'inputs.json')
    if read(run / 'exit.json') != {'returncode': 0}:
        raise ValueError('Run has not successfully exited')
    name = inputs['artifact']
    if not re.fullmatch(r'farpane-native-dev-[0-9a-f]{24}', name):
        raise ValueError('Invalid artifact identity')
    artifact = ROOT / 'Build/Linux/artifacts' / name
    manifest_bytes = (artifact / 'manifest.json').read_bytes()
    if hashlib.sha256(manifest_bytes).hexdigest() != inputs['manifest_sha256']:
        raise ValueError('Artifact manifest changed')
    manifest = json.loads(manifest_bytes)
    binaries = read(run / 'run/test-binaries.json')
    expected = {f['path']: f['sha256'] for f in manifest['files'] if f['path'] in binaries}
    if binaries != expected or set(binaries) != {'farpane', 'libexec/farpane-core'}:
        raise ValueError('Measured binaries do not match frozen artifact')
    for name, expected_sha in inputs['sources'].items():
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts:
            raise ValueError('Invalid captured source path')
        if hashlib.sha256((run / 'source' / name).read_bytes()).hexdigest() != expected_sha:
            raise ValueError('Captured test source changed')
    paths = sorted((run / 'run').glob('sample-*/result.json'))
    records = [read(path) for path in paths]
    result = read(run / 'run/sustained-result.json')
    validate(records, result, inputs['seconds'])
    summary = summarize(records, result, args.clock_ticks)
    summary.update(artifact=inputs['artifact'], manifest_sha256=inputs['manifest_sha256'],
                   image=inputs['image'], test_binaries=binaries)
    rows = []
    for r in records:
        row = {'index': r['index'], 'seconds': r['seconds'], 'color': r['color'],
               'pixel_observation_seconds': r['fresh_pixel_observation_seconds']}
        for role in ROLES:
            for key in ('pss_kib', 'uss_kib', 'fd_count', 'threads', 'cpu_ticks'):
                row[role + '_' + key] = r['processes'][role][key]
        rows.append(row)
    with (run / 'trend.csv').open('w') as stream:
        writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
        writer.writeheader(); writer.writerows(rows)
    (run / 'analysis.json').write_text(json.dumps(summary, indent=2) + '\n')
    if args.plot:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        fig, axes = plt.subplots(2, 1, figsize=(9, 6), sharex=True, constrained_layout=True)
        x = [r['seconds'] / 60 for r in records]
        for role in ROLES:
            baseline = summary['resources'][role]['baseline_pss_kib']
            axes[0].plot(x, [(r['processes'][role]['pss_kib'] - baseline) / 1024 for r in records], label=role)
            axes[1].plot(x, [r['processes'][role]['fd_count'] for r in records], label=role)
        axes[0].set_title('FarPane .20261018.3: one continuous software session\n'
                          'Private Xvfb, 640 x 480; PSS baseline after 40 seconds')
        axes[0].set_ylabel('PSS growth (MiB)')
        axes[1].set_ylabel('File descriptors'); axes[1].set_xlabel('Minutes since first confirmed frame')
        for axis in axes:
            axis.legend(); axis.grid(alpha=.2)
        fig.savefig(run / 'trend.png', dpi=150); plt.close(fig)
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
