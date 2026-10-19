import unittest
from unittest.mock import patch

import native_desktop_launch_vm as probe


class DesktopLaunchBoundary(unittest.TestCase):
    def test_keyboard_refuses_host_before_open(self):
        with patch.object(probe.Path,'read_text',return_value='root=/dev/workstation'), \
             patch.object(probe.os,'open') as opened:
            with self.assertRaises(AssertionError):probe.Keyboard(1)
            opened.assert_not_called()

    def test_capture_refuses_host_before_loading_library(self):
        with patch.object(probe.Path,'read_text',return_value='root=/dev/workstation'), \
             patch.object(probe.C,'CDLL') as library:
            with self.assertRaises(AssertionError):probe.capture('ignored','launch-ignored')
            library.assert_not_called()

    def test_launch_refuses_host_before_process_or_bus(self):
        with patch.object(probe.Path,'read_text',return_value='root=/dev/workstation'), \
             patch.object(probe.subprocess,'run') as run, \
             patch.object(probe.subprocess,'Popen') as start:
            with self.assertRaises(AssertionError):probe.exercise(None,None,None)
            run.assert_not_called();start.assert_not_called()

    def test_transport_comparison_refuses_other_profile_before_writes(self):
        with patch.object(probe,'require_probe'), \
             patch.object(probe,'require_maintenance',return_value=({}, {
                 'desktop_lifecycle_probe':True,'desktop_launch_transport':'exec'})), \
             patch.object(probe.Path,'write_bytes') as write, \
             patch.object(probe.subprocess,'Popen') as start:
            with self.assertRaises(AssertionError):probe.exercise(None,None,None)
            write.assert_not_called();start.assert_not_called()

    def test_unknown_transport_refused_before_writes(self):
        with patch.object(probe,'require_probe'), \
             patch.object(probe,'require_maintenance',return_value=({}, {
                 'desktop_launch_probe':True,'desktop_launch_transport':'unknown'})), \
             patch.object(probe.Path,'write_bytes') as write:
            with self.assertRaises(AssertionError):probe.exercise(None,None,None)
            write.assert_not_called()


if __name__=='__main__':unittest.main()
