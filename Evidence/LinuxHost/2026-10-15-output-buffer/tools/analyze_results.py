#!/usr/bin/env python3
"""汇总实验样本；保留无效标记，不从部分数据冒充完整结论。"""
import datetime
import json
import pathlib
import statistics
import argparse
import gzip

parser = argparse.ArgumentParser()
parser.add_argument('--data-root', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent)
ROOT = parser.parse_args().data_root.resolve()


def epoch(text):
    return datetime.datetime.fromisoformat(text.replace('Z', '+00:00')).timestamp()


def percentile(values, fraction):
    values = sorted(values)
    if not values:
        return None
    pos = (len(values) - 1) * fraction
    lower = int(pos)
    return values[lower] + (values[min(lower + 1, len(values) - 1)] - values[lower]) * (pos - lower)


def clock_point(path):
    if not path.exists():
        return None
    samples = json.loads(path.read_text())
    return (statistics.median(r['remote_epoch'] for r in samples),
            statistics.median(r['offset_remote_minus_local_s'] for r in samples))


start_clock = clock_point(ROOT / 'results/clock-calibration-start.json')
end_clock = clock_point(ROOT / 'results/clock-calibration-end.json')


def offset(remote_epoch):
    if end_clock and end_clock[0] > start_clock[0]:
        ratio = (remote_epoch - start_clock[0]) / (end_clock[0] - start_clock[0])
        return start_clock[1] + ratio * (end_clock[1] - start_clock[1])
    return start_clock[1]


cases = []
missing = []
for round_id in range(1, 4):
    for variant in ['A', 'B']:
        for mode in ['static', 'scroll', 'motion']:
            path = ROOT / 'results' / f'{variant}-{mode}-{round_id}.json'
            if not path.exists():
                missing.append(path.name)
                continue
            data = json.loads(path.read_text())
            row = {'case': path.stem, **data['parameters'], 'start_utc': data['start_utc'],
                   'end_utc': data['end_utc'], 'duration_s': data['duration_s'],
                   'issues': list(data['issues']), 'means': data['means'],
                   'source_animation_fps': data.get('source_animation_fps'),
                   'fixture_backend': data.get('fixture_backend'), 'viewport': data.get('viewport')}
            for endpoint in ['initial', 'final']:
                procs = [v for v in data[endpoint].values() if v['name'] == 'rustdesk']
                row[endpoint + '_pss_mib'] = sum(v.get('memory_kib', {}).get('Pss', 0) for v in procs) / 1024
                row[endpoint + '_uss_mib'] = sum(v.get('memory_kib', {}).get('Private_Clean', 0) +
                                                v.get('memory_kib', {}).get('Private_Dirty', 0) for v in procs) / 1024
                row[endpoint + '_server_pss_mib'] = sum(v.get('memory_kib', {}).get('Pss', 0) for v in procs if v.get('role') == '--server') / 1024
            row['cpu_sample_sd'] = statistics.stdev(s['rustdesk'] for s in data['samples'])
            if data['duration_s'] < 119 or len(data['samples']) != 60:
                row['issues'].append('incomplete 120 second sample')
            cases.append(row)

viewer_rows = []
if cases:
    earliest = min(epoch(c['start_utc']) - offset(epoch(c['start_utc'])) for c in cases) - 10
    archive = ROOT / 'results/viewer-samples.jsonl.gz'
    if archive.exists():
        with gzip.open(archive, 'rt') as stream:
            viewer_rows = [json.loads(line) for line in stream]
    else:
        for path in (pathlib.Path.home() / 'Library/Logs/FarPane/ViewerSession').glob('*.jsonl'):
            if path.stat().st_mtime < earliest:
                continue
            for line in path.open():
                item = json.loads(line)
                if item.get('capturedAt') and item.get('event') == 'periodic' and epoch(item['capturedAt']) >= earliest:
                    viewer_rows.append(item)
viewer_rows.sort(key=lambda r: r['capturedAt'])

for case in cases:
    remote_start, remote_end = epoch(case['start_utc']), epoch(case['end_utc'])
    left = remote_start - offset(remote_start) + 2
    right = remote_end - offset(remote_end) - 2
    rows = [r for r in viewer_rows if left <= epoch(r['capturedAt']) <= right]
    v = {'samples': len(rows), 'states': sorted({r['coreState'] for r in rows}),
         'generations': sorted({r['coreGeneration'] for r in rows})}
    if rows:
        duration = epoch(rows[-1]['capturedAt']) - epoch(rows[0]['capturedAt'])
        first, last = rows[0]['pipeline'], rows[-1]['pipeline']
        for key in ['receivedFPS', 'presentedFPS', 'networkDelayMS', 'presentationAgeMS',
                    'videoReceiveAgeMS', 'decoderQueueDepth', 'rendererQueueDepth', 'targetBitrate']:
            values = [r['pipeline'][key] for r in rows if key in r['pipeline']]
            if values:
                v[key] = {'mean': statistics.mean(values), 'p95': percentile(values, .95), 'max': max(values)}
        for key in ['decodeErrors', 'decoderResets', 'packetSequenceGaps', 'decodedFrames',
                    'presentedFrames', 'droppedFrames', 'receivedBytes', 'receivedPackets']:
            v[key + '_delta'] = last.get(key, 0) - first.get(key, 0)
        v['decoded_rate'] = v['decodedFrames_delta'] / duration if duration else None
        v['presented_rate'] = v['presentedFrames_delta'] / duration if duration else None
        v['observed_bitrate_kbps'] = v['receivedBytes_delta'] * 8 / duration / 1000 if duration else None
        if any(v[key + '_delta'] != 0 for key in ['decodeErrors', 'decoderResets', 'packetSequenceGaps']):
            case['issues'].append('viewer errors/resets/gaps changed')
    if len(rows) < 110 or v['states'] != ['streaming'] or len(v['generations']) != 1:
        case['issues'].append('viewer coverage/state/generation not stable')
    case['viewer'] = v

scenarios = {}
for mode in ['static', 'scroll', 'motion']:
    groups = {variant: [r for r in cases if r['mode'] == mode and r['variant'] == variant] for variant in ['A', 'B']}
    item = {}
    for variant, group in groups.items():
        values = [r['means']['rustdesk'] for r in group]
        if not values:
            continue
        item[variant] = {'runs': len(group), 'cpu_values': values, 'cpu_median': statistics.median(values),
                         'cpu_min': min(values), 'cpu_max': max(values),
                         'drm_cpu_median': statistics.median(r['means']['drm_recv'] for r in group),
                         'pss_mib_median': statistics.median(r['final_pss_mib'] for r in group),
                         'package_w_median': statistics.median(r['means']['rapl_package-0_w'] for r in group),
                         'source_fps_min': min(r.get('source_animation_fps', 0) for r in group)}
    if 'A' in item and 'B' in item:
        item['relative_cpu_reduction_pct'] = (item['A']['cpu_median'] - item['B']['cpu_median']) / item['A']['cpu_median'] * 100
        item['run_ranges_separated'] = item['A']['cpu_min'] > item['B']['cpu_max']
    scenarios[mode] = item

summary = {'expected_cases': 18, 'available_cases': len(cases), 'missing': missing,
           'case_integrity_complete': not missing and not any(r['issues'] for r in cases),
           'clock_start': start_clock, 'clock_end': end_clock, 'scenarios': scenarios, 'cases': cases,
           'latency_scope': 'network RTT and receive/presentation-age proxies; not glass-to-glass latency',
           'power_scope': 'RAPL package-0; not wall-plug power; amdgpu power is not added to it'}
(ROOT / 'results/analysis.json').write_text(json.dumps(summary, indent=2))
print(json.dumps({k: v for k, v in summary.items() if k != 'cases'}, indent=2))
print('case issues', [(r['case'], r['issues']) for r in cases if r['issues']])
