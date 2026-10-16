#!/usr/bin/env python3
"""临时切换 1080p 并恢复原模式；不写入持久显示配置。"""
import datetime
import json
import pathlib
import signal
import time
import urllib.request
from gi.repository import Gio, GLib

ROOT = pathlib.Path('/home/xiaobei/services/rustdesk-host-perf-20261015')
proxy = Gio.DBusProxy.new_for_bus_sync(Gio.BusType.SESSION, Gio.DBusProxyFlags.DO_NOT_AUTO_START,
    None, 'org.gnome.Mutter.DisplayConfig', '/org/gnome/Mutter/DisplayConfig',
    'org.gnome.Mutter.DisplayConfig', None)


def state():
    return proxy.call_sync('GetCurrentState', None, Gio.DBusCallFlags.NONE, 5000, None).unpack()


def current_mode(snapshot):
    return next(m for m in snapshot[1][0][1] if m[6].get('is-current') is True)


initial = state()
if len(initial[1]) != 1 or len(initial[2]) != 1 or initial[1][0][0][0] != 'Virtual-1':
    raise SystemExit('Unexpected monitor topology; no change made')
original = current_mode(initial)
target = next(m for m in initial[1][0][1] if m[1:3] == (1920, 1080) or list(m[1:3]) == [1920, 1080])
logical = initial[2][0]
monitor_props = initial[1][0][2]
if monitor_props.get('rgb-range', 1) != 1:
    raise SystemExit('Non-default RGB range; no change made')
events = []


def apply(mode_id, method):
    serial = state()[0]
    properties = {'color-mode': GLib.Variant('u', monitor_props.get('color-mode', 0))}
    if 'is-underscanning' in monitor_props:
        properties['underscanning'] = GLib.Variant('b', monitor_props['is-underscanning'])
    config = [(logical[0], logical[1], logical[2], logical[3], logical[4], [('Virtual-1', mode_id, properties)])]
    params = GLib.Variant('(uua(iiduba(ssa{sv}))a{sv})', (serial, method, config,
        {'layout-mode': GLib.Variant('u', initial[3].get('layout-mode', 1))}))
    proxy.call_sync('ApplyMonitorsConfig', params, Gio.DBusCallFlags.NONE, 5000, None)


def record(label):
    snap = state()
    item = {'event': label, 'time_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'mode': list(current_mode(snap)[:4]),
            'fixture': json.load(urllib.request.urlopen('http://127.0.0.1:47651/state', timeout=3))}
    events.append(item)
    print(json.dumps(item), flush=True)


def interrupted(_sig, _frame):
    raise KeyboardInterrupt


signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGHUP, interrupted)
apply(target[0], 0)
try:
    record('before')
    apply(target[0], 1)
    time.sleep(3)
    record('1080p')
    time.sleep(20)
    apply(original[0], 1)
    time.sleep(3)
    record('restored-1440p')
    time.sleep(20)
finally:
    apply(original[0], 1)
    record('final-restored')
    (ROOT / 'results' / 'geometry-B2.json').write_text(json.dumps(events, indent=2))
