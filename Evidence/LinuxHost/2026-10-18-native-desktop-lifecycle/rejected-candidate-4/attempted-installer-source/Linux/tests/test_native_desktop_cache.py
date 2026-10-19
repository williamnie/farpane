import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Linux/packaging'))
from native_user_install import UserIntegration


class DesktopCache(unittest.TestCase):
    def setUp(self):
        parent=ROOT/'Build/Linux/desktop-cache-unit';parent.mkdir(exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(dir=parent)
        self.directory=Path(self.tmp.name)
        self.desktop=self.directory/'org.farpane.FarPane.desktop'
        self.desktop.write_text('[Desktop Entry]\nType=Application\nName=FarPane\nExec=/bin/true\n')
        self.before=self.desktop.read_bytes()
        self.user=object.__new__(UserIntegration)
        self.user.uid=os.geteuid();self.user.private_gid=os.getegid()
        self.user.paths={'desktop':self.desktop}

    def tearDown(self):self.tmp.cleanup()

    def test_failed_refresh_keeps_entries_and_can_retry(self):
        with patch('native_user_install.subprocess.run',return_value=subprocess.CompletedProcess([],1)):
            failed=self.user.refresh_desktop_cache()
        self.assertEqual(failed['status'],'failed')
        self.assertEqual(self.desktop.read_bytes(),self.before)
        with patch('native_user_install.subprocess.run',return_value=subprocess.CompletedProcess([],0)) as run:
            recovered=self.user.refresh_desktop_cache()
        self.assertEqual(recovered['status'],'refreshed')
        self.assertEqual(run.call_args.args[0],['/usr/bin/update-desktop-database','--quiet',str(self.directory)])
        self.assertEqual(self.desktop.read_bytes(),self.before)

    def test_symlink_cache_is_not_overwritten(self):
        sentinel=self.directory/'user-document';sentinel.write_text('keep')
        (self.directory/'mimeinfo.cache').symlink_to(sentinel)
        with patch('native_user_install.subprocess.run') as run:
            with self.assertRaises(ValueError):self.user.refresh_desktop_cache()
            run.assert_not_called()
        self.assertEqual(sentinel.read_text(),'keep')

    def test_missing_helper_and_timeout_report_failure_without_entry_rollback(self):
        for error,status,started in [(FileNotFoundError(),'unavailable',False),
                                     (subprocess.TimeoutExpired('cache',10),'failed',True)]:
            with self.subTest(status=status),patch('native_user_install.subprocess.run',side_effect=error):
                result=self.user.refresh_desktop_cache()
            self.assertEqual((result['status'],result['helper_started']),(status,started))
            self.assertEqual(self.desktop.read_bytes(),self.before)


if __name__=='__main__':unittest.main()
