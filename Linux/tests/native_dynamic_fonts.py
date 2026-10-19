"""Show a synthetic device alias, its editor and the restored private Home."""
import json
from pathlib import Path
import re
import subprocess
import time

from native_host_smoke import cli, RELEASE
from native_viewer_smoke import memory_breakdown

ALIAS = '龘 靐 齉 爨 한 Ω Probe'
PEER = '123456789'


def widgets(directory, phase, gui):
    root = directory / 'widgets'
    (root / 'request').write_text(phase)
    target = root / (phase + '.json')
    deadline = time.monotonic() + 5
    while True:
        assert gui.poll() is None and time.monotonic() < deadline, 'GTK observation timed out'
        try: data = json.loads(target.read_text())
        except (FileNotFoundError, json.JSONDecodeError): time.sleep(.05); continue
        assert not data['truncated'] and data['widgets']
        for row in data['widgets']:
            if 'unknown_glyphs' in row:
                assert row['unknown_glyphs'] == 0, row
        return data['widgets']


def settle(gui, agent, seconds=5):
    began = time.monotonic()
    while time.monotonic() - began < seconds:
        assert gui.poll() is None and agent.poll() is None
        time.sleep(.05)


def sample(directory, phase, gui):
    proc = Path('/proc') / str(gui.pid)
    assert (proc / 'exe').resolve() == RELEASE / 'farpane'
    smaps = (proc / 'smaps').read_text(); rollup = (proc / 'smaps_rollup').read_text()
    (directory / (phase + '-smaps.txt')).write_text(smaps)
    (directory / (phase + '-rollup.txt')).write_text(rollup)
    mappings = memory_breakdown(smaps)
    (directory / (phase + '-mappings.json')).write_text(json.dumps(mappings, indent=2) + '\n')
    values = {k: int(v) for k, v in re.findall(r'^(\w+):\s+(\d+) kB$', rollup, re.M)}
    children = set()
    for task in (proc / 'task').iterdir():
        try: children.update((task / 'children').read_text().split())
        except FileNotFoundError: pass
    assert not children and values['SwapPss'] == 0
    return {'phase': phase, 'pss_kib': values['Pss'],
            'uss_kib': values['Private_Clean'] + values['Private_Dirty'],
            'font_pss_kib': sum(row['Pss'] for row in mappings['mappings'] if '/fonts/' in row['path']),
            'fd_count': len(list((proc / 'fd').iterdir())), 'child_count': 0, 'swap_pss_kib': 0}


def scroll(screen, down):
    # Right edge of the outer page, outside the nested device-list scroller.
    screen.t.XTestFakeMotionEvent(screen.display, -1, 1004, 600, 0)
    for _ in range(30):
        screen.t.XTestFakeButtonEvent(screen.display, 5 if down else 4, 1, 0)
        screen.t.XTestFakeButtonEvent(screen.display, 5 if down else 4, 0, 0)
        screen.x.XFlush(screen.display)
        time.sleep(.01)


def click_widget(screen, row):
    tree = subprocess.check_output(['xwininfo', '-display', ':92', '-id', str(row['surface_xid'])], text=True)
    origin = [int(re.search(r'Absolute upper-left ' + axis + r':\s*(-?\d+)', tree)[1]) for axis in ('X', 'Y')]
    x, y, width, height = row['bounds']
    point = (round(origin[0] + x + width / 2), round(origin[1] + y + height / 2))
    assert 0 <= point[0] < 1020 and 0 <= point[1] < 720
    screen.click(point)


def exercise(directory, screen, gui, agent, initial):
    assert not initial['devices']
    probe = json.loads(Path('/fonts/probe.json').read_text())
    assert all(ord(char) not in probe['codepoints'] for char in '龘靐齉爨한Ω')
    home = widgets(directory, 'home', gui)
    assert not any(row.get('text') == ALIAS for row in home)
    current = cli({'type': 'snapshot'})
    current = cli({'type': 'remember_device', 'data': {
        'peer': PEER, 'server': current['server'], 'revision': current['revision']}})
    current = cli({'type': 'set_device', 'data': {
        'peer': PEER, 'alias': ALIAS, 'favorite': False, 'revision': current['revision']}})
    assert len(current['devices']) == 1 and current['devices'][0]['alias'] == ALIAS
    scroll(screen, True); settle(gui, agent)
    alias = widgets(directory, 'alias', gui)
    labels = [row for row in alias if row['type'] == 'GtkLabel' and row.get('text') == ALIAS]
    assert len(labels) == 1 and labels[0]['unknown_glyphs'] == 0, alias
    samples = [sample(directory, 'alias', gui)]
    screen.capture(directory / 'alias.png')
    buttons = [row for row in alias if row['name'] == 'device-edit-' + PEER]
    assert len(buttons) == 1, buttons
    click_widget(screen, buttons[0]); settle(gui, agent)
    edit = widgets(directory, 'edit', gui)
    entries = [row for row in edit if row['name'] == 'device-alias']
    assert len(entries) == 1 and entries[0]['text'] == ALIAS, edit
    assert any(row.get('text') == '编辑设备' for row in edit)
    samples.append(sample(directory, 'edit', gui))
    screen.capture(directory / 'edit.png')
    # Close the private edit dialog without changing the stored alias.
    screen.key(0xff1b, True); screen.key(0xff1b, False)
    current = cli({'type': 'snapshot'})
    assert current['devices'][0]['alias'] == ALIAS
    current = cli({'type': 'forget_device', 'data': {'peer': PEER, 'revision': current['revision']}})
    assert not current['devices']
    scroll(screen, False); settle(gui, agent)
    returned = widgets(directory, 'returned', gui)
    assert not any(row.get('text') == ALIAS or row['name'] == 'device-alias' for row in returned)
    assert any(row.get('text') == '你的设备' for row in returned)
    samples.append(sample(directory, 'returned', gui))
    screen.capture(directory / 'returned.png')
    for key in ('local_id', 'server', 'host_enabled', 'gpu_enabled', 'inbound'):
        assert current[key] == initial[key], key
    result = {'alias': ALIAS, 'samples': samples, 'visible_alias_label': labels[0],
              'editor_buffer_matches': True, 'catalog_restored': True,
              'revision_after': current['revision'], 'read_only_widget_observer': True,
              'actual_label_missing_glyphs': 0, 'editable_glyphs_not_introspected': True}
    (directory / 'dynamic-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    return result
