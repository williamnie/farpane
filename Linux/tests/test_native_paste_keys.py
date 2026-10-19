import importlib.util
import os
from pathlib import Path
import struct
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('paste_keys', ROOT / 'Linux/diagnostics/paste_keys.py')
keys = importlib.util.module_from_spec(spec)
spec.loader.exec_module(keys)


def event(kind, code, value, usec=0):
    return keys.EVENT.pack(100, usec, kind, code, value)


class Filtering(unittest.TestCase):
    def test_other_keys_and_scan_codes_never_leave_parser(self):
        reader = keys.Frames()
        data = b''.join(event(1, code, 1) + event(0, 0, 0)
                        for code in range(256) if code not in keys.KEYS)
        for offset in range(0, len(data), keys.EVENT.size * 128):
            self.assertEqual(reader.feed(data[offset:offset + keys.EVENT.size * 128]), [])
        self.assertEqual(reader.feed(event(4, 4, 42) + event(0, 0, 0)), [])
        self.assertEqual(reader.count, 0)

    def test_complete_chord_keeps_order_and_kernel_timing(self):
        reader = keys.Frames()
        out = reader.feed(b''.join(event(1, code, value, i * 100) + event(0, 0, 0)
                                  for i, (code, value) in enumerate([(42, 1), (110, 1), (110, 0), (42, 0)])))
        self.assertEqual([(r[0]['code'], r[0]['state'], r[0]['relative_us']) for r in out],
                         [(42, 'down', 0), (110, 'down', 100), (110, 'up', 200), (42, 'up', 300)])

    def test_pending_frame_not_reported_until_syn(self):
        reader = keys.Frames()
        self.assertEqual(reader.feed(event(1, 42, 1)), [])
        self.assertEqual(len(reader.feed(event(0, 0, 0))), 1)

    def test_lost_events_discard_pending_frame_and_fail(self):
        reader = keys.Frames()
        reader.feed(event(1, 42, 1))
        with self.assertRaisesRegex(ValueError, 'kernel_events_lost'):
            reader.feed(event(0, 3, 0))
        self.assertEqual(reader.pending, [])

    def test_truncated_invalid_and_oversized_input_fail(self):
        for data in (b'\0', event(1, 42, 9), event(1, 42, 1, 1000000), event(0, 0, 0) * 257):
            with self.assertRaises(ValueError):
                keys.Frames().feed(data)

    def test_bounded_event_count_and_frame(self):
        with self.assertRaises(ValueError):
            keys.Frames().feed(event(1, 42, 1) * 33)
        reader = keys.Frames()
        for _ in range(256):
            reader.feed(event(1, 42, 1) + event(0, 0, 0))
        with self.assertRaises(ValueError):
            reader.feed(event(1, 42, 1))

    def test_no_user_selected_device_path(self):
        for path in ('/dev/input/by-id/fake', '/tmp/event0', '/dev/input/../event0'):
            with patch.object(keys.os, 'open') as opened:
                with self.assertRaises(ValueError):
                    keys.open_reader({'path': path})
                opened.assert_not_called()

    def test_sysname_rejects_paths_and_wrong_objects(self):
        for value in (b'../event0\0', b'event7\0', b'input1/../../x\0'):
            with patch.object(keys, 'read_ioctl', return_value=value):
                with self.assertRaises(ValueError):
                    keys.sysname(1)

    def test_mask_bits_are_only_whitelisted_keys(self):
        data = keys.bitmap(keys.KEYS)
        self.assertEqual([i for i in range(len(data) * 8) if data[i // 8] & (1 << (i % 8))],
                         sorted(keys.KEYS))

    def test_state_never_exports_normal_keys(self):
        with patch.object(keys, 'read_ioctl', return_value=keys.bitmap([30, 31, 42, 110])):
            self.assertEqual(keys.key_state(1), ['left_shift', 'insert'])

    def test_cli_without_window_never_gets_to_devices(self):
        import subprocess
        result = subprocess.run(['python3', '-B', str(ROOT / 'Scripts/linux/observe-native-paste-keys.py'),
                                 '--uid', '1000', '--release', '/opt/farpane/releases/nope'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('--approved-test-window', result.stderr)


if __name__ == '__main__':
    unittest.main()
