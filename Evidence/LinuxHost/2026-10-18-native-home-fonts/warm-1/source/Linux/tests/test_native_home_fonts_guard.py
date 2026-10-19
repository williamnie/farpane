"""Ensure the font experiment cannot use a host display, device or config."""
import os
from pathlib import Path
import unittest
from unittest.mock import patch

from native_home_fonts import guard
from native_viewer_smoke import user_test


class FontGuard(unittest.TestCase):
    def test_private_environment_and_rejected_boundaries(self):
        env = {'FARPANE_NATIVE_TEST_MODE': 'home-fonts',
               'HOME': '/run/farpane-native-test/user',
               'XDG_RUNTIME_DIR': '/run/farpane-native-test/user'}
        with patch.dict(os.environ, env, clear=True), patch('os.geteuid', return_value=1000), \
                patch.object(Path, 'is_file', return_value=True), \
                patch.object(Path, 'exists', return_value=False):
            guard()
            for key, value in (('DISPLAY', ':0'), ('WAYLAND_DISPLAY', 'wayland-0'),
                               ('HOME', '/home/user'), ('XDG_RUNTIME_DIR', '/run/user/1000'),
                               ('FARPANE_NATIVE_TEST_MODE', 'gpu')):
                with self.subTest(key=key), patch.dict(os.environ, {key: value}):
                    with self.assertRaises(ValueError):
                        guard()
            for device in ('/dev/dri', '/dev/input', '/dev/uinput', '/dev/kvm'):
                with self.subTest(device=device), patch.object(
                        Path, 'exists', lambda path: str(path) == device):
                    with self.assertRaises(ValueError):
                        guard()
            with patch('os.geteuid', return_value=0), self.assertRaises(ValueError):
                guard()
            with patch.object(Path, 'is_file', return_value=False), self.assertRaises(ValueError):
                guard()

    def test_rejection_precedes_configuration_and_processes(self):
        with patch.dict(os.environ, {'FARPANE_NATIVE_TEST_MODE': 'home-fonts'}, clear=True), \
                patch('native_viewer_smoke.cli') as cli, \
                patch('subprocess.Popen') as popen, self.assertRaises(ValueError):
            user_test(Path('/must-not-be-created'))
        cli.assert_not_called()
        popen.assert_not_called()


if __name__ == '__main__':
    unittest.main()
