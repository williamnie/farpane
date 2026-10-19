import unittest
from unittest.mock import patch

import native_desktop_lifecycle_vm as probe


class LifecycleBoundary(unittest.TestCase):
    def test_host_refused_before_keyboard_gui_or_bus(self):
        with patch.object(probe.Path, 'read_text', return_value='root=/dev/workstation'), \
             patch.object(probe, 'Keyboard') as keyboard, \
             patch.object(probe.subprocess, 'run') as run, \
             patch.object(probe.subprocess, 'Popen') as start:
            with self.assertRaises(AssertionError): probe.exercise(None, None, None)
            keyboard.assert_not_called(); run.assert_not_called(); start.assert_not_called()

    def test_other_maintenance_profile_refused_before_capture_guard(self):
        with patch.object(probe, 'require_maintenance', return_value=({}, {'desktop_launch_probe': True})), \
             patch.object(probe, 'require_probe') as capture_guard:
            with self.assertRaises(AssertionError): probe.require_lifecycle()
            capture_guard.assert_not_called()

    def test_unbounded_index_wait_refused_before_capture_guard(self):
        with patch.object(probe, 'require_maintenance', return_value=({}, {
                'desktop_lifecycle_probe': True, 'desktop_index_settle_seconds': 300})), \
             patch.object(probe, 'require_probe') as capture_guard:
            with self.assertRaises(AssertionError): probe.require_lifecycle()
            capture_guard.assert_not_called()


if __name__ == '__main__': unittest.main()
