"""Negative checks for host misuse and stale-pixel false positives."""
import os
from pathlib import Path
import unittest
from unittest.mock import patch

from native_sustained_smoke import color_for, guard, patch_pixels


class SustainedGuard(unittest.TestCase):
    def test_host_invocation_is_rejected(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ValueError):
                guard()

    def test_display_and_devices_are_not_accepted(self):
        env = {'FARPANE_NATIVE_TEST_MODE': 'sustained',
               'XDG_RUNTIME_DIR': '/run/farpane-native-test/user',
               'HOME': '/run/farpane-native-test/user', 'FARPANE_SUSTAINED_SECONDS': '60'}
        with patch.dict(os.environ, env, clear=True), patch('os.geteuid', return_value=1000), \
                patch.object(Path, 'is_file', return_value=True), patch.object(Path, 'exists', return_value=False):
            self.assertEqual(guard(), 60)
            os.environ['DISPLAY'] = ':0'
            with self.assertRaises(ValueError):
                guard()
            del os.environ['DISPLAY']
            with patch.object(Path, 'exists', side_effect=lambda: True):
                with self.assertRaises(ValueError):
                    guard()
            os.environ['FARPANE_SUSTAINED_SECONDS'] = '86400'
            with self.assertRaises(ValueError):
                guard()

    def test_challenges_do_not_match_stale_frames(self):
        colors = [color_for(i) for i in range(91)]
        triples = [[(c >> shift) & 255 for shift in (16, 8, 0)] for c in colors]
        for i, current in enumerate(triples):
            self.assertGreaterEqual(max(current) - min(current), 88)
            for previous in triples[:i]:
                # No RGB pixel can be within +/-12 of two challenge colors.
                self.assertGreater(max(abs(a - b) for a, b in zip(current, previous)), 24)
        with self.assertRaises(ValueError):
            color_for(-1)
        with self.assertRaises(ValueError):
            color_for(216)

    def test_unrelated_pixels_do_not_satisfy_remote_patch(self):
        color = color_for(4)
        pixel = bytes((color & 255, (color >> 8) & 255, color >> 16, 0))
        stride = 1020 * 4
        raw = bytearray(pixel * (1020 * 720))
        for y in range(300, 480):
            raw[y * stride + 380 * 4:y * stride + 640 * 4] = bytes(260 * 4)
        self.assertEqual(patch_pixels((raw, stride), color), 0)
        for y in range(300, 480):
            raw[y * stride + 380 * 4:y * stride + 640 * 4] = pixel * 260
        self.assertEqual(patch_pixels((raw, stride), color), 260 * 180)


if __name__ == '__main__':
    unittest.main()
