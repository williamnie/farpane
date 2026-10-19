"""Maintenance may control services only after validating the separate guest."""
import json
import unittest
from unittest.mock import patch

import native_maintenance_vm as maintenance


class MaintenanceBoundary(unittest.TestCase):
    def test_host_boot_rejected_before_writes_and_commands(self):
        with patch.object(maintenance.Path,'read_text',return_value='root=/dev/workstation'), \
             patch.object(maintenance.Path,'mkdir') as mkdir, \
             patch.object(maintenance.subprocess,'run') as run:
            with self.assertRaises(AssertionError):maintenance.controller()
            mkdir.assert_not_called();run.assert_not_called()

    def test_input_guest_is_not_maintenance_authority(self):
        with patch.object(maintenance,'require_guest',return_value={'boot_id':'private-test'}), \
             patch.object(maintenance.Path,'read_text',return_value=json.dumps({'scenario':'input'})), \
             patch.object(maintenance.Path,'mkdir') as mkdir, \
             patch.object(maintenance.subprocess,'run') as run:
            with self.assertRaises(AssertionError):maintenance.controller()
            mkdir.assert_not_called();run.assert_not_called()


if __name__=='__main__':unittest.main()
