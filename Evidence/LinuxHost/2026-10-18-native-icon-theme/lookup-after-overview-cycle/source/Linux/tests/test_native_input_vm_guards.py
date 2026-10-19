"""These entrypoints must refuse workstation execution before any mutation."""
import unittest
from unittest.mock import patch

import native_input_vm_init as guest
import native_input_vm_service as service
import native_input_vm_desktop as desktop
import native_input_vm_network as network
import native_input_vm_wire as wire


class GuestBoundary(unittest.TestCase):
    def test_mount_entry_refuses_non_guest_pid(self):
        with patch.object(guest.os,'getpid',return_value=4321), \
             patch.object(guest.os,'geteuid',return_value=0), \
             patch.object(guest.subprocess,'run') as run:
            with self.assertRaises(AssertionError):
                guest.mount_filesystems()
            run.assert_not_called()

    def test_input_probe_refuses_before_opening_device(self):
        with patch.object(guest.os,'getpid',return_value=4321), \
             patch.object(guest.os,'geteuid',return_value=0), \
             patch.object(guest.os,'open') as opened:
            with self.assertRaises(AssertionError):
                guest.kernel_input_probe()
            opened.assert_not_called()

    def test_service_fixture_refuses_before_starting_processes(self):
        with patch.object(service.os,'getpid',return_value=4321), \
             patch.object(service.os,'geteuid',return_value=0), \
             patch.object(service.subprocess,'Popen') as start:
            with self.assertRaises(AssertionError):
                service.exercise()
            start.assert_not_called()

    def test_desktop_controller_refuses_host_boot_before_systemctl_or_reboot(self):
        with patch.object(desktop.Path,'read_text',return_value='root=/dev/workstation'), \
             patch.object(desktop.subprocess,'run') as run, \
             patch.object(desktop.ctypes,'CDLL') as libc:
            with self.assertRaises(AssertionError):
                desktop.controller()
            run.assert_not_called()
            libc.assert_not_called()

    def test_desktop_user_session_refuses_host_boot(self):
        with patch.object(desktop.Path,'read_text',return_value='root=/dev/workstation'), \
             patch.object(desktop.subprocess,'Popen') as start:
            with self.assertRaises(AssertionError):
                desktop.session()
            start.assert_not_called()

    def test_network_input_refuses_host_before_device_or_gui(self):
        with patch.object(desktop.Path,'read_text',return_value='root=/dev/workstation'), \
             patch.object(network.os,'open') as opened, \
             patch.object(network.subprocess,'Popen') as start:
            with self.assertRaises(AssertionError):
                network.exercise(None,None,None,None)
            opened.assert_not_called()
            start.assert_not_called()

    def test_wire_peer_refuses_host_before_network_connect(self):
        with patch.object(desktop.Path,'read_text',return_value='root=/dev/workstation'), \
             patch.object(wire.socket,'create_connection') as connect:
            with self.assertRaises(AssertionError):wire.Peer({})
            connect.assert_not_called()

    def test_wire_driver_refuses_host_before_device_open(self):
        with patch.object(desktop.Path,'read_text',return_value='root=/dev/workstation'), \
             patch.object(wire.os,'open') as opened:
            with self.assertRaises(AssertionError):wire.exercise(None,None,None,None)
            opened.assert_not_called()


if __name__ == '__main__':
    unittest.main()
