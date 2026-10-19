#!/usr/bin/env python3
"""Reject damaged copies of an actual completed series; never start the app."""
import argparse
import copy
import importlib.util
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location('sustained_analysis',
        root / 'Scripts/linux/analyze-native-sustained.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    source = args.run / 'run'
    records = [json.loads(p.read_text()) for p in sorted(source.glob('sample-*/result.json'))]
    result = json.loads((source / 'sustained-result.json').read_text())
    assert result['requested_seconds'] == 60
    module.validate(records, result, 60)
    checks = ['actual_short_run_accepted_as_short_only']

    def reject(label, mutate, seconds=60, summarize=False):
        data, report = copy.deepcopy(records), copy.deepcopy(result)
        mutate(data, report)
        try:
            module.validate(data, report, seconds)
            if summarize:
                module.summarize(data, report, 100)
        except ValueError:
            checks.append(label)
        else:
            raise AssertionError('Damaged evidence accepted: ' + label)

    reject('missing_final_sample_rejected', lambda rows, _: rows.pop())
    reject('short_run_cannot_claim_30_minutes',
           lambda _, report: report.update(requested_seconds=1800, thirty_minute_gate=True), seconds=1800)
    reject('worker_identity_replacement_rejected',
           lambda rows, _: rows[50]['processes']['viewer'].update(start_ticks=0))
    reject('stale_color_replay_rejected', lambda rows, _: rows[50].update(color=rows[49]['color']))
    reject('nan_timing_rejected', lambda rows, _: rows[50].update(seconds=float('nan')))
    reject('unreaped_worker_rejected', lambda _, report: report.update(worker_reaped=False))

    def extra_fd(rows, report):
        process = rows[-1]['processes']['viewer']
        process['fds']['1000'] = 'socket:[synthetic-damage]'
        process['fd_count'] += 1
    reject('fd_growth_cannot_claim_stable', extra_fd, summarize=True)
    print(json.dumps({'result': 'pass', 'checks': checks,
                      'source_records_modified': False, 'product_executed': False}, indent=2))


if __name__ == '__main__':
    main()
