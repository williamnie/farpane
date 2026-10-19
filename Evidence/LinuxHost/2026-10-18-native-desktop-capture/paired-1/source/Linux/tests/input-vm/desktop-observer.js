// Private GNOME diagnostic: observe associations without refreshing them.
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import Shell from 'gi://Shell';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const decoder = new TextDecoder();
const read = path => decoder.decode(GLib.file_get_contents(path)[1]);

export default class DesktopObserver extends Extension {
    enable() {
        const marker = JSON.parse(read('/.farpane-input-vm'));
        if (!read('/proc/cmdline').split(/\s+/).includes('farpane.input-vm=1') ||
            read('/proc/1/comm').trim() !== 'systemd' ||
            marker.scenario !== 'maintenance' || marker.stage !== 'desktop' ||
            marker.desktop_launch_probe !== true || marker.desktop_shell_observer !== true)
            throw new Error('FarPane desktop observer requires the marked private VM');
        this._rows = [];
        this._connections = [];
        this._idle = 0;
        this._last = '';
        this._captures = new Set();
        this._capturing = false;
        this._tracker = Shell.WindowTracker.get_default();
        const connect = (object, signal, callback) =>
            this._connections.push([object, object.connect(signal, callback)]);
        connect(this._tracker, 'tracked-windows-changed', () => this._sample('tracked-windows'));
        connect(Shell.AppSystem.get_default(), 'installed-changed', () => this._sample('installed', true));
        connect(global.display, 'window-created', () => this._sample('created'));
        this._export = Gio.DBusExportedObject.wrapJSObject(
            '<node><interface name="org.farpane.PrivateDesktopTest">' +
            '<method name="Capture"><arg type="s" direction="in"/>' +
            '<arg type="s" direction="out"/></method></interface></node>', this);
        this._export.export(Gio.DBus.session, '/org/farpane/PrivateDesktopTest');
        this._sample('enabled', true);
    }

    CaptureAsync([name], invocation) {
        if (!['cli', 'dbus', 'cli-late'].includes(name) ||
            this._captures.has(name) || this._capturing) {
            invocation.return_dbus_error('org.farpane.PrivateDesktopTest.InvalidCapture',
                'Only one bounded capture per selected private launch case');
            return;
        }
        this._captures.add(name);
        this._capturing = true;
        let stream = null;
        const fail = error => {
            if (stream) stream.close(null);
            this._capturing = false;
            invocation.return_dbus_error('org.farpane.PrivateDesktopTest.CaptureFailed', String(error));
        };
        try {
            const file = `launch-shell-${name}.png`;
            stream = Gio.File.new_for_path(`/run/farpane-input-results/${file}`)
                .create(Gio.FileCreateFlags.PRIVATE, null);
            const screenshot = new Shell.Screenshot();
            this._sample(`capture-${name}`, true);
            screenshot.screenshot(false, stream, (source, result) => {
                try {
                    const [ok, area] = source.screenshot_finish(result);
                    if (!ok) throw new Error('Shell screenshot failed');
                    stream.close(null);
                    stream = null;
                    this._capturing = false;
                    invocation.return_value(new GLib.Variant('(s)', [JSON.stringify({
                        file, seconds: GLib.get_monotonic_time() / 1000000,
                        width: area.width, height: area.height, x: area.x, y: area.y,
                        capture: 'GNOME Shell.Screenshot; cursor excluded; no flash',
                    })]));
                } catch (error) { fail(error); }
            });
        } catch (error) { fail(error); }
    }

    _sample(event, force = false) {
        const windows = global.get_window_actors().map(actor => actor.meta_window)
            .filter(window => window.get_title() === 'FarPane')
            .map(window => {
                const app = this._tracker.get_window_app(window);
                const preview = window._delegate?._icon;
                return {pid: window.get_pid(), sequence: window.get_stable_sequence(),
                    wm_class: window.get_wm_class(), gtk_app_id: window.get_gtk_application_id(),
                    app_id: app?.get_id() ?? null, window_backed: app?.is_window_backed() ?? null,
                    app_icon: app?.get_icon()?.to_string() ?? null,
                    preview_icon: preview?.gicon?.to_string() ?? null};
            });
        const value = JSON.stringify(windows);
        if ((force || value !== this._last) && this._rows.length < 128) {
            this._last = value;
            this._rows.push({seconds: GLib.get_monotonic_time() / 1000000, event, windows});
            GLib.file_set_contents('/run/farpane-input-results/desktop-shell-observer.log',
                JSON.stringify(this._rows, null, 2) + '\n');
        }
        if (event !== 'idle' && !this._idle) {
            this._idle = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
                this._idle = 0;
                this._sample('idle');
                return GLib.SOURCE_REMOVE;
            });
        }
    }

    disable() {
        this._export?.unexport();
        for (const [object, id] of this._connections ?? []) object.disconnect(id);
        if (this._idle) GLib.source_remove(this._idle);
        this._connections = [];
        this._idle = 0;
    }
}
