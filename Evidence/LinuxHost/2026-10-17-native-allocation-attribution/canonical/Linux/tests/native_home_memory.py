"""Observe the real idle Home without starting a Viewer or exporting a texture."""
import json
import os
from pathlib import Path
import re
import subprocess
import time

from native_host_smoke import cli, RELEASE
from native_viewer_smoke import memory_breakdown


def exercise(output, start, agent, initial):
    directory = output / 'home-idle'
    directory.mkdir()
    env = dict(os.environ, GDK_BACKEND='wayland', WAYLAND_DISPLAY='farpane-test-wayland',
               GSK_RENDERER='gl', GTK_A11Y='none', GTK_IM_MODULE='gtk-im-context-simple')
    env.pop('DISPLAY', None)
    env.pop('FARPANE_VIEWER_SMOKE_DIR', None)
    mode = os.environ.get('FARPANE_NATIVE_MEMORY_PROBE', 'baseline')
    assert mode in ('identity', 'mmap128k', 'allocations'), 'Idle probe requires actual GL identity'
    env['LD_PRELOAD'] = str(output / 'gl-identity.so')
    if mode == 'mmap128k':
        env.update(MALLOC_MMAP_THRESHOLD_='131072', MALLOC_TRIM_THRESHOLD_='131072')
    if mode == 'allocations':
        asan = Path('/usr/lib/x86_64-linux-gnu/libasan.so.8')
        assert asan.is_file()
        env.update(LD_PRELOAD=':'.join((str(asan), str(output/'allocation-profile.so'), str(output/'gl-identity.so'))),
                   FARPANE_ALLOCATION_PROFILE='1',
                   ASAN_OPTIONS='detect_leaks=0:quarantine_size_mb=16:thread_local_quarantine_size_kb=64:'
                                'malloc_context_size=20:fast_unwind_on_malloc=0:symbolize=0')
    gui = start('home-gui', [str(RELEASE / 'farpane')], env)
    began = time.monotonic()
    samples = []
    for second in (3, 10, 30):
        while time.monotonic() - began < second:
            assert gui.poll() is None and agent.poll() is None, 'Private GUI/agent exited'
            time.sleep(.05)
        proc = Path('/proc') / str(gui.pid)
        assert (proc / 'exe').resolve() == RELEASE / 'farpane'
        smaps = (proc / 'smaps').read_text()
        rollup = (proc / 'smaps_rollup').read_text()
        (directory / f'{second}s-smaps.txt').write_text(smaps)
        (directory / f'{second}s-rollup.txt').write_text(rollup)
        breakdown = memory_breakdown(smaps)
        (directory / f'{second}s-mappings.json').write_text(json.dumps(breakdown, indent=2) + '\n')
        memory = {key: int(value) for key, value in re.findall(r'^(\w+):\s+(\d+) kB$', rollup, re.M)}
        stat = (proc / 'stat').read_text().rsplit(') ', 1)[1].split()
        children = set()
        for task in (proc / 'task').iterdir():
            try:
                children.update((task / 'children').read_text().split())
            except FileNotFoundError:
                pass
        assert not children, 'Home unexpectedly retained child processes'
        drm = {}
        for info in (proc / 'fdinfo').iterdir():
            try:
                text = info.read_text()
            except FileNotFoundError:
                continue
            client = re.search(r'^drm-client-id:\s*(\d+)', text, re.M)
            if client:
                drm[client[1]] = '\n'.join(line for line in text.splitlines() if line.startswith('drm-'))
        samples.append({'seconds': time.monotonic() - began, 'pss_kib': memory['Pss'],
                        'uss_kib': memory['Private_Clean'] + memory['Private_Dirty'],
                        'rss_kib': memory['Rss'], 'swap_pss_kib': memory['SwapPss'],
                        'cpu_ticks': int(stat[11]) + int(stat[12]), 'threads': int(stat[17]),
                        'fd_count': len(list((proc / 'fd').iterdir())), 'child_count': len(children),
                        'drm_clients': drm})
    if mode == 'allocations':
        # Wait for the diagnostic report, never treat a truncated report as a
        # completed inventory. The outer GPU runner retains its 90s bound.
        while 'FARPANE_ALLOCATION_PROFILE_END=20\n' not in (output/'home-gui.log').read_text():
            assert gui.poll() is None and agent.poll() is None and time.monotonic()-began < 60
            time.sleep(.1)
    log = (output / 'home-gui.log').read_text()
    identity = {key: re.findall(r'^FARPANE_GL_' + key + r'=(.+)$', log, re.M)
                for key in ('VENDOR', 'RENDERER', 'VERSION')}
    assert all(len(v) == 1 and v[0] != 'unavailable' for v in identity.values()), identity
    assert 'CRITICAL' not in log, log
    if mode == 'allocations':
        for second in (20,):
            assert log.count(f'FARPANE_ALLOCATION_PROFILE_BEGIN={second}\n') == 1
            assert log.count(f'FARPANE_ALLOCATION_PROFILE_END={second}\n') == 1
        assert log.count('Live Heap Allocations:') == 1
    after = cli({'type': 'snapshot'})
    for key in ('local_id', 'server', 'revision', 'host_enabled', 'gpu_enabled',
                'permanent_password_set', 'temporary_password', 'inbound'):
        assert after[key] == initial[key], key
    assert not after['inbound'] and agent.poll() is None
    cpu = 100 * (samples[-1]['cpu_ticks'] - samples[0]['cpu_ticks']) / os.sysconf('SC_CLK_TCK')
    cpu /= samples[-1]['seconds'] - samples[0]['seconds']
    result = {'result': 'pass', 'measurement': 'idle-home-no-viewer', 'allocator_probe': mode,
              'samples': samples, 'cpu_percent_one_core_3_to_30s': cpu,
              'memory_60_mib_target_met': None if mode == 'allocations' else max(s['pss_kib'] for s in samples) <= 60 * 1024,
              'cpu_half_percent_target_met': None if mode == 'allocations' else cpu <= .5,
              'diagnostic_allocator_replaced': mode == 'allocations',
              'product_memory_cpu_measurement': mode != 'allocations',
              'gl_identity': {k: v[0] for k, v in identity.items()},
              'screenshots_exported': False, 'host_configuration_preserved': True,
              'real_desktop_tested': False, 'product_changed': False}
    (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
    gui.terminate()
    try:
        gui.wait(timeout=3)
    except subprocess.TimeoutExpired:
        gui.kill()
        gui.wait(timeout=3)
