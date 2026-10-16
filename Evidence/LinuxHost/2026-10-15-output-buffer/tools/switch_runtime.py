#!/usr/bin/env python3
"""串行切换临时测试服务；正式安装文件保持原样。"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import time

ROOT = pathlib.Path('/home/user/services/rustdesk-host-perf-20261015')
STATE = ROOT / 'runtime.json'
EXPECTED = {
    'A': '43e158c4b5922c707965382300a825b49b5c7cdf1411d1da6ff43af63c4f3a71',
    'B': '7aece4647c50c31e496843f0c61b88577f01707d0621624faa6b3820b6a22931',
}


def run(*args, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=True)


def stop_test():
    if not STATE.exists():
        return
    unit = json.loads(STATE.read_text()).get('unit', '')
    if not re.fullmatch(r'farpane-host-perf-[AB]-[0-9]+\.service', unit):
        raise RuntimeError('Unexpected test unit identity')
    loaded = run('systemctl', 'show', '-p', 'LoadState', '--value', unit, check=False)
    if loaded.stdout.strip() == 'loaded':
        run('systemctl', 'stop', unit)


def server_for(executable):
    matches = []
    for p in pathlib.Path('/proc').iterdir():
        if not p.name.isdigit():
            continue
        try:
            if (p / 'comm').read_text().strip() != 'rustdesk':
                continue
            if b'--server' in (p / 'cmdline').read_bytes().split(b'\0'):
                matches.append((int(p.name), str((p / 'exe').readlink())))
        except (FileNotFoundError, ProcessLookupError):
            continue
    return matches[0][0] if len(matches) == 1 and matches[0][1] == str(executable) else None


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('variant', choices=['A', 'B', 'original'])
    parser.add_argument('--round', type=int, default=0)
    args = parser.parse_args()
    if args.variant != 'original':
        # 上游 ExecStop 的 pkill 模式也会匹配 rustc 的 librustdesk 参数。
        # 测试切换前拒绝可能被它误伤的编译/审查命令，不修改已安装服务。
        for process in pathlib.Path('/proc').iterdir():
            if not process.name.isdigit():
                continue
            try:
                name = (process / 'comm').read_text().strip()
                command = (process / 'cmdline').read_bytes().replace(b'\0', b' ')
                if b'rustdesk --' in command and name not in ('rustdesk', 'sudo', 'pkill'):
                    raise SystemExit(f'Wait for conflicting {name} process {process.name}; service untouched')
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                continue
        bundle = ROOT / 'bundles' / args.variant
        actual = hashlib.sha256((bundle / 'lib/librustdesk.so').read_bytes()).hexdigest()
        if actual != EXPECTED[args.variant]:
            raise SystemExit('Artifact hash mismatch; service untouched')
    stop_test()
    if args.variant == 'original':
        run('systemctl', 'start', 'rustdesk.service')
        STATE.unlink(missing_ok=True)
        print('Original rustdesk.service restored', flush=True)
        raise SystemExit(0)
    unit = f'farpane-host-perf-{args.variant}-{args.round}.service'
    STATE.write_text(json.dumps({'unit': unit, 'variant': args.variant, 'round': args.round}))
    try:
        run('systemctl', 'stop', 'rustdesk.service')
        run('systemd-run', '--unit=' + unit, '--collect',
            '--property=Type=simple', '--property=KillMode=control-group',
            '--property=RuntimeMaxSec=3600', '--property=OnFailure=rustdesk.service',
            '--setenv=PULSE_LATENCY_MSEC=60', '--setenv=PIPEWIRE_LATENCY=1024/48000',
            str(bundle / 'rustdesk'), '--service')
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            pid = server_for(bundle / 'rustdesk')
            if pid:
                print(json.dumps({'variant': args.variant, 'unit': unit, 'server_pid': pid}), flush=True)
                break
            time.sleep(.5)
        else:
            raise RuntimeError('Test server did not start; rolling back')
    except BaseException:
        run('systemctl', 'stop', unit, check=False)
        run('systemctl', 'start', 'rustdesk.service', check=False)
        raise
