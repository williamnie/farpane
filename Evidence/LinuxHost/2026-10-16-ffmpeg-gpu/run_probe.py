#!/usr/bin/env python3
"""本机观察既有 Viewer；出现退化就通知远端只停止实验进程。"""
import argparse
import datetime
import json
import pathlib
import selectors
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent
REMOTE = '/home/user/services/farpane-ffmpeg-gpu-20261016'


def viewer():
    paths = pathlib.Path.home().joinpath('Library/Logs/FarPane/ViewerSession').glob('viewer-session-*.jsonl')
    p = max(paths, key=lambda x: x.stat().st_mtime)
    with p.open('rb') as f:
        f.seek(max(0, p.stat().st_size - 12000))
        rows = f.read().splitlines()
    for line in reversed(rows):
        try:
            d = json.loads(line)
            if d.get('event') == 'periodic':
                return {'log_age_s': time.time()-p.stat().st_mtime,
                        **{k: d[k] for k in ('capturedAt', 'coreGeneration', 'coreState', 'pipeline')}}
        except (ValueError, KeyError):
            continue
    raise RuntimeError('No recent Viewer sample')


def run(mode, label, seconds):
    first = viewer()
    if first['log_age_s'] > 5 or first['coreState'] != 'streaming':
        raise RuntimeError('Viewer is not healthy before test')
    if (ROOT / (label + '.jsonl')).exists():
        raise RuntimeError('Refusing to replace previous evidence')
    command = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', 'linux-host',
               'sudo', '-n', 'python3', REMOTE+'/remote_probe.py', mode, label, '--seconds', str(seconds)]
    p = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, bufsize=1)
    sel = selectors.DefaultSelector()
    sel.register(p.stdout, selectors.EVENT_READ, 'out')
    sel.register(p.stderr, selectors.EVENT_READ, 'err')
    start = last_check = time.monotonic()
    errors = []
    low_fps = 0
    received_final = False
    with (ROOT/(label+'.jsonl')).open('x') as output, (ROOT/(label+'-viewer.jsonl')).open('x') as vlog:
        try:
            while p.poll() is None or sel.get_map():
                now = time.monotonic()
                if now-last_check >= 1 and p.poll() is None:
                    v = viewer()
                    vlog.write(json.dumps(v)+'\n');vlog.flush()
                    pipe = v['pipeline']
                    low_fps = low_fps+1 if pipe['receivedFPS'] < 26 or pipe['presentedFPS'] < 24 else 0
                    if v['log_age_s'] > 5 or v['coreState'] != 'streaming' or v['coreGeneration'] != first['coreGeneration']:
                        errors.append('Viewer stale/state/generation changed')
                    if any(pipe[k] > first['pipeline'][k] for k in ('decodeErrors','decoderResets','referenceFrameDrops','packetSequenceGaps')):
                        errors.append('Viewer new error or packet gap')
                    if low_fps >= 3 or pipe['videoReceiveAgeMS'] > 1000 or pipe['presentationAgeMS'] > 1000:
                        errors.append('Viewer stalled or sustained FPS reduction')
                    if now-start > seconds+30:
                        errors.append('Overall test deadline exceeded')
                    try:
                        p.stdin.write('STOP\n' if errors else 'HEARTBEAT\n');p.stdin.flush()
                    except BrokenPipeError:
                        pass
                    last_check = now
                for key, _ in sel.select(.2):
                    line = key.fileobj.readline()
                    if not line:
                        sel.unregister(key.fileobj)
                        continue
                    if key.data == 'err':
                        print(line.rstrip(),flush=True)
                        continue
                    output.write(line);output.flush()
                    d = json.loads(line)
                    if d['event'] == 'complete':
                        received_final = True
                        print(json.dumps({'label':label,'summary':d['summary'],'issues':d['issues'], 'exit_code':d['exit_code']}),flush=True)
                    elif d['event'] == 'started' or round(d.get('elapsed_s', 0)) % 20 == 0:
                        print(line.rstrip(),flush=True)
        finally:
            if p.poll() is None:
                try:
                    p.stdin.write('STOP\n');p.stdin.flush()
                except BrokenPipeError:
                    pass
                p.wait(timeout=15)
            sel.close()
    result={'label':label,'controller_errors':errors,'ssh_exit':p.returncode,'received_final':received_final}
    (ROOT/(label+'-controller.json')).write_text(json.dumps(result,indent=2))
    if errors or p.returncode or not received_final:
        raise RuntimeError(result)


if __name__ == '__main__':
    ap=argparse.ArgumentParser();ap.add_argument('mode',choices=['baseline','gpu','ram']);ap.add_argument('label');ap.add_argument('--seconds',type=int,default=60)
    a=ap.parse_args();run(a.mode,a.label,a.seconds)
