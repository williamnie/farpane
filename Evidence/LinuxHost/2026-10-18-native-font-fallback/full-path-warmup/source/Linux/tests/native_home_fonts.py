"""Private software-GL font attribution; never a hardware memory acceptance."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

from native_host_smoke import RELEASE, cli
from native_lifecycle_smoke import Display
from native_viewer_smoke import memory_breakdown


def guard():
    if (not Path('/.dockerenv').is_file() or os.geteuid() == 0
            or os.environ.get('FARPANE_NATIVE_TEST_MODE') != 'home-fonts'
            or os.environ.get('XDG_RUNTIME_DIR') != '/run/farpane-native-test/user'
            or os.environ.get('HOME') != '/run/farpane-native-test/user'
            or any(Path(p).exists() for p in ('/dev/dri', '/dev/input', '/dev/uinput', '/dev/kvm'))
            or os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY')):
        raise ValueError('Requires the marked private software-only font experiment')


def match_font(env, point, bold=False):
    pattern = f'sans-serif:charset={point:x}' + (':weight=bold' if bold else '')
    data = subprocess.check_output(['fc-match', '-f', '%{file}\n%{index}\n%{charset}\n', pattern],
                                   env=env, text=True, timeout=10).splitlines()
    assert len(data) == 3
    ranges = [tuple(int(value, 16) for value in word.split('-')) for word in data[2].split()]
    assert any(values[0] <= point <= values[-1] for values in ranges), (point, data[:2])
    return {'file': data[0], 'face': int(data[1]), 'contains_codepoint': True}


def exercise(output, start, agent, initial):
    guard()  # Before font queries, GUI, capture or configuration calls.
    probe = json.loads(Path('/fonts/probe.json').read_text())
    for font in probe['fonts']:
        assert hashlib.sha256((Path('/fonts') / font['file']).read_bytes()).hexdigest() == font['sha256']
    base = dict(os.environ, DISPLAY=':92', GSK_RENDERER='gl', GTK_A11Y='none',
                LIBGL_ALWAYS_SOFTWARE='1', GALLIUM_DRIVER='llvmpipe',
                GTK_IM_MODULE='gtk-im-context-simple')
    assert not any(key.startswith('FARPANE_') and ('SMOKE_DIR' in key or 'SMOKE_REPORT' in key
                   or 'MEMORY_PROBE' in key or 'SMOKE_EXIT' in key) for key in base)
    base.pop('FONTCONFIG_FILE', None)
    environments = {'baseline': base, 'subset': dict(base, FONTCONFIG_FILE='/fonts/fonts.conf')}
    matches = {name: {label: match_font(env, point, bold) for label, point, bold in (
        ('ui_regular', 0x4f60, False), ('ui_bold', 0x4f60, True),
        ('latin', 0x41, False), ('greek', 0x3a9, False), ('cjk_fallback', 0x9f98, False),
        ('korean_fallback', 0xd55c, False))} for name, env in environments.items()}
    for label in ('ui_regular', 'ui_bold'):
        assert matches['subset'][label]['file'].startswith('/fonts/fonts/'), matches
    for label in ('latin', 'greek', 'cjk_fallback', 'korean_fallback'):
        assert matches['subset'][label] == matches['baseline'][label], (label, matches)
    (output / 'font-matches.json').write_text(json.dumps(matches, indent=2) + '\n')
    shapes = {}
    for name, env in environments.items():
        result = subprocess.check_output([sys.executable, '-B',
            '/workspace/Linux/tests/native_font_shapes.py'], env=env, text=True, timeout=15)
        shapes[name] = json.loads(result)
    (output / 'font-shapes.json').write_text(json.dumps(shapes, ensure_ascii=False, indent=2) + '\n')
    for variant, cases in shapes.items():
        for label, case in cases.items():
            assert case['unknown_glyphs'] == 0, (variant, label, case['unknown_glyphs'])
    assert shapes['baseline']['fallback_regular'] == shapes['subset']['fallback_regular']
    assert shapes['baseline']['fallback_bold'] == shapes['subset']['fallback_bold']
    # Both variants render once before sampling: the first software-GL process
    # can retain shader-compilation allocations not present on later launches.
    warmups = []
    dynamic = os.environ.get('FARPANE_NATIVE_FONT_DYNAMIC') == '1'
    for variant, env in environments.items():
        warm_env = dict(env)
        directory = output / ('home-warmup-' + variant)
        if dynamic:
            directory.mkdir()
            (directory / 'widgets').mkdir(mode=0o700)
            warm_env.update(LD_PRELOAD=str(output / 'font-widgets.so'),
                            FARPANE_FONT_WIDGET_DIR=str(directory / 'widgets'))
        gui = start('warmup-' + variant, [str(RELEASE / 'farpane')], warm_env)
        began = time.monotonic()
        try:
            while time.monotonic() - began < 5:
                assert gui.poll() is None and agent.poll() is None
                time.sleep(.05)
            tree = subprocess.check_output(['xwininfo', '-display', ':92', '-root', '-tree'], text=True)
            assert '"FarPane"' in tree, tree
            assert 'CRITICAL' not in (output / ('warmup-' + variant + '.log')).read_text()
            extra = None
            if dynamic:
                # Opening the editor introduces additional GL programs. Warm
                # the full path before treating phase differences as savings.
                from native_dynamic_fonts import exercise as exercise_dynamic
                screen = Display(':92')
                try: extra = exercise_dynamic(directory, screen, gui, agent, initial)
                finally: screen.close()
            warmups.append({'variant': variant, 'gui_pid': gui.pid,
                            'seconds': time.monotonic() - began,
                            'dynamic_path_completed': extra is not None})
        finally:
            gui.terminate()
            try: gui.wait(timeout=5)
            except subprocess.TimeoutExpired: gui.kill(); gui.wait(timeout=5)
            assert not Path('/proc', str(gui.pid)).exists()
    screen = Display(':92')
    records = []
    try:
        for index, variant in enumerate(('baseline', 'subset', 'subset', 'baseline')):
            directory = output / f'home-{index}-{variant}'; directory.mkdir()
            env = dict(environments[variant])
            if dynamic:
                (directory / 'widgets').mkdir(mode=0o700)
                env.update(LD_PRELOAD=str(output / 'font-widgets.so'),
                           FARPANE_FONT_WIDGET_DIR=str(directory / 'widgets'))
            gui = start(f'home-{index}-{variant}', [str(RELEASE / 'farpane')], env)
            began = time.monotonic(); samples = []
            try:
                for second in (3, 10, 20):
                    while time.monotonic() - began < second:
                        assert gui.poll() is None and agent.poll() is None
                        time.sleep(.05)
                    proc = Path('/proc') / str(gui.pid)
                    assert (proc / 'exe').resolve() == RELEASE / 'farpane'
                    smaps = (proc / 'smaps').read_text(); rollup = (proc / 'smaps_rollup').read_text()
                    (directory / f'{second}s-smaps.txt').write_text(smaps)
                    (directory / f'{second}s-rollup.txt').write_text(rollup)
                    breakdown = memory_breakdown(smaps)
                    (directory / f'{second}s-mappings.json').write_text(json.dumps(breakdown, indent=2) + '\n')
                    values = dict((k, int(v)) for k, v in re.findall(r'^(\w+):\s+(\d+) kB$', rollup, re.M))
                    children = set()
                    for task in (proc / 'task').iterdir():
                        try: children.update((task / 'children').read_text().split())
                        except FileNotFoundError: pass
                    assert not children
                    samples.append({'seconds': time.monotonic() - began, 'pss_kib': values['Pss'],
                        'uss_kib': values['Private_Clean'] + values['Private_Dirty'],
                        'font_pss_kib': sum(m['Pss'] for m in breakdown['mappings'] if '/fonts/' in m['path']),
                        'swap_pss_kib': values['SwapPss'], 'fd_count': len(list((proc / 'fd').iterdir()))})
                # External capture happens after the memory samples.
                screen.capture(directory / 'home.png')
                extra = None
                if dynamic:
                    from native_dynamic_fonts import exercise as exercise_dynamic
                    extra = exercise_dynamic(directory, screen, gui, agent, initial)
                assert 'CRITICAL' not in (output / f'home-{index}-{variant}.log').read_text()
                after = cli({'type': 'snapshot'})
                for key in ('local_id', 'revision', 'host_enabled', 'gpu_enabled', 'inbound'):
                    expected = extra['revision_after'] if extra and key == 'revision' else initial[key]
                    assert after[key] == expected, key
                records.append({'variant': variant, 'gui_pid': gui.pid, 'samples': samples,
                                'dynamic': extra})
            finally:
                gui.terminate()
                try: gui.wait(timeout=5)
                except subprocess.TimeoutExpired: gui.kill(); gui.wait(timeout=5)
                assert not Path('/proc', str(gui.pid)).exists()
        result = {'result': 'pass', 'records': records, 'warmups': warmups, 'software_only': True,
                  'renderer': 'GL requested, llvmpipe forced, no device access',
                  'hardware_memory_target_evaluated': False, 'product_font_changed': False,
                  'chinese_input_tested': False, 'font_matching_checks': matches,
                  'widget_observer_enabled': os.environ.get('FARPANE_NATIVE_FONT_DYNAMIC') == '1',
                  'pango_missing_glyphs': 0, 'fallback_shaping_preserved': True}
        (output / 'home-font-result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result), flush=True)
    finally:
        screen.close()
