#!/usr/bin/env python3
"""AB / BA / AB 顺序，完成或失败后均恢复正式服务。"""
import datetime
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path('/home/user/services/rustdesk-host-perf-20261015')


def event(kind, **fields):
    print(json.dumps({'event': kind, 'time_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), **fields}), flush=True)


if __name__ == '__main__':
    completed = []
    try:
        for round_id, order in enumerate([['A', 'B'], ['B', 'A'], ['A', 'B']], 1):
            for variant in order:
                event('switch', variant=variant, round=round_id)
                subprocess.run(['python3', str(ROOT / 'switch_runtime.py'), variant, '--round', str(round_id)], check=True)
                time.sleep(10)
                for mode in ['static', 'scroll', 'motion']:
                    event('case_start', variant=variant, round=round_id, mode=mode)
                    subprocess.run(['python3', '-u', str(ROOT / 'measure.py'), '--variant', variant,
                                    '--round', str(round_id), '--mode', mode, '--seconds', '120', '--warmup', '15'], check=True)
                    completed.append(f'{variant}-{mode}-{round_id}.json')
                    event('case_complete', count=len(completed), total=18)
        event('matrix_complete', files=completed)
    finally:
        restored = subprocess.run(['python3', str(ROOT / 'switch_runtime.py'), 'original'])
        event('restored_original', returncode=restored.returncode, completed=completed)
