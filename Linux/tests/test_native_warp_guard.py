import unittest
from unittest.mock import patch

import native_warp_bootstrap as warp
import native_paste_target_test as selector


class WarpIsolation(unittest.TestCase):
    def test_selector_refuses_host_before_launch(self):
        with patch.object(selector.Path,'is_file',return_value=False), \
             patch.object(selector.subprocess,'Popen') as start:
            with self.assertRaises(AssertionError):selector.exercise(None,None)
            start.assert_not_called()

    def test_host_refused_before_launch(self):
        with patch.object(warp.Path,'is_file',return_value=False), \
             patch.object(warp.subprocess,'Popen') as start:
            with self.assertRaises(AssertionError):warp.exercise()
            start.assert_not_called()

    def test_inherited_display_refused_before_launch(self):
        with patch.object(warp.Path,'is_file',return_value=True), \
             patch.object(warp.Path,'exists',return_value=False), \
             patch.object(warp.os,'geteuid',return_value=1000), \
             patch.dict(warp.os.environ,{'DISPLAY':':0'}), \
             patch.object(warp.subprocess,'Popen') as start:
            with self.assertRaises(AssertionError):warp.exercise()
            start.assert_not_called()


if __name__=='__main__':unittest.main()
