#!/usr/bin/env python3
import datetime
import json
import pathlib
import re
import subprocess
import time
import urllib.request

ROOT = pathlib.Path('/home/user/services/rustdesk-host-perf-20261015')


def state():
    return json.load(urllib.request.urlopen('http://127.0.0.1:47651/state', timeout=3))


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


try:
    for variant in ['A', 'B']:
        result = subprocess.run(['python3', str(ROOT/'switch_runtime.py'), variant, '--round', '88'],
                                check=True, capture_output=True, text=True)
        identity = json.loads(result.stdout.strip())
        urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:47651/mode',
            data=json.dumps({'mode':'scroll'}).encode()), timeout=3).close()
        time.sleep(25)
        before = state()
        start = utc()
        log = ROOT/'logs'/f'capture-stage-{variant}-final.txt'
        with log.open('w') as stream:
            process = subprocess.run(['bpftrace', str(ROOT/'capture-stage.bt'), str(identity['server_pid'])],
                                     stdout=stream, stderr=subprocess.STDOUT)
        after = state()
        text = log.read_text()
        frames = [list(map(int, line.split(',')[1:])) for line in text.splitlines() if line.startswith('FRAME,')]
        counts = {name: int(value) for name,value in re.findall(r'^@(\w+): (\d+)$',text,re.M)}
        report = {'variant':variant,'start_utc':start,'end_utc':utc(),'before':before,'after':after,
                  'identity':identity,'exit_code':process.returncode,'counts':counts,'frames_us':frames,
                  'script_sha256':__import__('hashlib').sha256((ROOT/'capture-stage.bt').read_bytes()).hexdigest()}
        report['valid'] = (process.returncode == 0 and before['generation']==after['generation']
            and before['focused'] and after['focused'] and len(frames)>=580
            and counts.get('missing_ack',0)==0 and counts.get('convert_count',0)-len(frames)<=1)
        (ROOT/'results'/f'capture-stage-{variant}-final.json').write_text(json.dumps(report,indent=2))
        print(json.dumps({'variant':variant,'valid':report['valid'],'counts':counts,'frames':len(frames)}),flush=True)
        if not report['valid']:
            raise RuntimeError('Incomplete capture timing observation')
finally:
    subprocess.run(['python3',str(ROOT/'switch_runtime.py'),'original'],check=True)
