#!/usr/bin/env python3
"""Compare allocator reports and residency in the same instrumented GUI run."""
import argparse
import csv
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('run', type=Path)
parser.add_argument('--plot', action='store_true')
args = parser.parse_args()
result = json.loads((args.run / 'lifecycle-result.json').read_text())
assert result['result'] == 'pass' and result['rounds'] == 20 and result['gobject_observer_enabled']
samples = [json.loads((args.run / f'cycle-{i:02d}/allocator.json').read_text()) for i in range(1, 22)]
objects = [json.loads((args.run / f'cycle-{i:02d}/object-counts.json').read_text()) for i in range(1, 22)]
assert all(s['exact_live_user_allocation_inventory'] is False for s in samples)
assert all(o['overflow'] == 0 and o['alive'] == o['created'] - o['destroyed'] for o in objects)
base = samples[0]
base_pss = result['records'][1]['idle']['gui']['pss_kib']
fields = ['arena_system_bytes', 'bin_free_bytes', 'arena_reported_nonfree_bytes',
          'mmap_bytes', 'reported_nonfree_plus_mmap_bytes']
rows = []
for i, sample in enumerate(samples):
    row = {'round': i, 'gui_pss_kib': result['records'][i + 1]['idle']['gui']['pss_kib'],
           'alive_objects': objects[i]['alive'], 'heap_count': len(sample['heaps'])}
    row['gui_pss_growth_bytes'] = (row['gui_pss_kib'] - base_pss) * 1024
    for key in fields:
        row[key] = sample[key]
        row[key + '_growth'] = sample[key] - base[key]
    rows.append(row)
first_types, last_types = objects[0]['types'], objects[-1]['types']
type_growth = {k: last_types.get(k, 0) - first_types.get(k, 0) for k in set(first_types) | set(last_types)}
heaps = []
assert [h['index'] for h in samples[-1]['heaps']] == [h['index'] for h in base['heaps']]
for before, after in zip(base['heaps'], samples[-1]['heaps']):
    delta = {k: after[k] - before[k] for k in ('system_bytes', 'bin_free_bytes', 'reported_nonfree_bytes')}
    if any(delta.values()):
        heaps.append({'index': before['index'], **delta})
summary = {'scope': 'same instrumented .5 GUI; allocator counters are not exact live user allocations',
           'glibc_version': base['glibc_version'], 'measured_rounds': 20,
           'heap_counts': sorted({len(s['heaps']) for s in samples}),
           'reported_arena_bin_kinds': base['reported_arena_bin_kinds'],
           'baseline': {k: base[k] for k in fields},
           'final': {k: samples[-1][k] for k in fields},
           'delta': {k: samples[-1][k] - base[k] for k in fields},
           'max_reported_nonfree_growth_bytes': max(r['reported_nonfree_plus_mmap_bytes_growth'] for r in rows),
           'max_gui_pss_growth_bytes': max(r['gui_pss_growth_bytes'] for r in rows),
           'final_gui_pss_growth_bytes': rows[-1]['gui_pss_growth_bytes'],
           'last_ten_gui_pss_growth_bytes': (rows[-1]['gui_pss_kib'] - rows[-10]['gui_pss_kib']) * 1024,
           'changed_heaps': heaps,
           'gobject_type_deltas': {k: v for k, v in sorted(type_growth.items()) if v},
           'gobject_baseline_alive': objects[0]['alive'], 'gobject_final_alive': objects[-1]['alive'],
           'allocator_default_changed': False, 'product_memory_budget_accepted': False,
           'persistent_growth_ruled_out': False, 'complete_plan_acceptance': False}
(args.run / 'allocator-analysis.json').write_text(json.dumps(summary, indent=2) + '\n')
with (args.run / 'allocator-trend.csv').open('w') as file:
    writer = csv.DictWriter(file, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
if args.plot:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(2, 1, figsize=(9, 6), sharex=True, constrained_layout=True)
    x = [r['round'] for r in rows]
    for key, label in [('gui_pss_growth_bytes', 'GUI PSS residency'),
                       ('reported_nonfree_plus_mmap_bytes_growth', 'Allocator reported non-free + mmap'),
                       ('arena_system_bytes_growth', 'Allocator arena system space')]:
        axes[0].plot(x, [r[key] / 1048576 for r in rows], marker='.', label=label)
    axes[0].set_ylabel('Growth from warm baseline (MiB)')
    axes[0].set_title('FarPane .5: allocator diagnostics across 20 software connections\nInstrumented run; not a product performance comparison')
    axes[0].legend()
    axes[1].plot(x, [r['alive_objects'] - rows[0]['alive_objects'] for r in rows], marker='.')
    axes[1].set_ylabel('Observed live GObject change')
    axes[1].set_xlabel('Connection / disconnect cycle after two warmups')
    axes[1].set_xticks([0, 5, 10, 15, 20])
    for axis in axes:
        axis.grid(alpha=.2)
    fig.savefig(args.run / 'allocator-trend.png', dpi=150)
    plt.close(fig)
print(json.dumps(summary, indent=2))
