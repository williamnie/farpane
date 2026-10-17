#!/usr/bin/env python3
"""Summarize repeated-connection evidence without treating bounded growth as no leak."""
import argparse
import csv
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('ordinary', type=Path)
parser.add_argument('--objects', type=Path)
parser.add_argument('--plot', action='store_true', help='Requires matplotlib; creates a standalone PNG')
args = parser.parse_args()
result = json.loads((args.ordinary / 'lifecycle-result.json').read_text())
assert result['rounds'] == 20 and len(result['records']) == 22
assert result.get('gobject_observer_enabled', False) is False
baseline = result['records'][1]['idle']
records = result['records'][2:]
rows = []
for index, row in enumerate(records, 1):
    entry = {'round': index, 'seconds': row['seconds'], 'worker_pid': row['worker_pid']}
    for role in ('gui', 'host'):
        current = row['idle'][role]
        entry[role + '_pss_kib'] = current['pss_kib']
        entry[role + '_growth_kib'] = current['pss_kib'] - baseline[role]['pss_kib']
        entry[role + '_fd'] = current['fd_count']
    entry['combined_growth_kib'] = entry['gui_growth_kib'] + entry['host_growth_kib']
    rows.append(entry)
summary = {k: v for k, v in result.items() if k != 'records'}
summary['scope'] = '20 software connections through external XTest; same GUI and Host'
summary['last_ten_rounds_growth_kib'] = {
    role: records[-1]['idle'][role]['pss_kib'] - records[-10]['idle'][role]['pss_kib']
    for role in ('gui', 'host')}
summary['persistent_growth_ruled_out'] = False
summary['complete_plan_acceptance'] = False
if args.objects:
    observer = json.loads((args.objects / 'lifecycle-result.json').read_text())
    assert observer['rounds'] == 20 and observer['gobject_observer_enabled']
    samples = [json.loads((args.objects / f'cycle-{index:02d}/object-counts.json').read_text())
               for index in range(1, 22)]
    assert all(d['overflow'] == 0 and d['alive'] == d['created'] - d['destroyed'] for d in samples)
    first, last = samples[0], samples[-1]
    deltas = {key: last['types'].get(key, 0) - first['types'].get(key, 0)
              for key in set(first['types']) | set(last['types'])}
    summary['object_observer'] = {
        'output': str(args.objects), 'counts_scope': 'intercepted public GObject constructors',
        'baseline_alive': first['alive'], 'final_alive': last['alive'],
        'final_created': last['created'], 'final_destroyed': last['destroyed'],
        'type_deltas': {key: value for key, value in sorted(deltas.items()) if value},
        'positive_type_growth': {key: value for key, value in sorted(deltas.items()) if value > 0},
        'overflow': 0, 'memory_budget_accepted': False,
        'not_a_complete_heap_inventory': True}
(args.ordinary / 'analysis.json').write_text(json.dumps(summary, indent=2) + '\n')
with (args.ordinary / 'trend.csv').open('w') as stream:
    writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
if args.plot:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(2, 1, figsize=(9, 6), sharex=True, constrained_layout=True)
    x = [row['round'] for row in rows]
    for key, label in [('gui', 'GUI'), ('host', 'Host'), ('combined', 'GUI + Host')]:
        axes[0].plot(x, [row[key + '_growth_kib'] / 1024 for row in rows], marker='.', label=label)
    axes[0].axhline(10, color='#aa5555', linestyle='--', label='10 MiB growth budget')
    axes[0].set_ylabel('Idle PSS growth (MiB)')
    axes[0].set_ylim(-.2, 10.5)
    axes[0].legend(loc='upper left', ncol=2)
    axes[0].set_title('FarPane .5: 20 software connections in one GUI\nBaseline after two warmups; 5 s idle after each disconnect')
    for role in ('gui', 'host'):
        axes[1].plot(x, [row[role + '_fd'] for row in rows], marker='.', label=role.upper())
    axes[1].set_xlabel('Measured connection / disconnect cycle')
    axes[1].set_ylabel('Idle file descriptors')
    axes[1].legend(loc='center left')
    axes[1].set_xticks([1, 5, 10, 15, 20])
    for axis in axes:
        axis.grid(alpha=.2)
    fig.savefig(args.ordinary / 'trend.png', dpi=150)
    plt.close(fig)
print(json.dumps(summary, indent=2))
