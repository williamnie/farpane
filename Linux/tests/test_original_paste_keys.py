import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / 'Scripts/linux/observe-original-paste-keys.py'
spec = importlib.util.spec_from_file_location('original_paste_keys', CLI)
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


class GuardTests(unittest.TestCase):
    def test_cli_requires_explicit_window_and_process(self):
        for args in ([], ['--uid', '1000', '--host-pid', '123'], ['--approved-test-window']):
            result = subprocess.run(['python3', '-B', str(CLI), *args], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)

    def test_duration_is_bounded_before_any_capture(self):
        result = subprocess.run(['python3', '-B', str(CLI), '--approved-test-window',
            '--uid', '1000', '--host-pid', '123', '--seconds', '61'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('ready', result.stdout)

    def test_farpane_running_prevents_opening_device(self):
        with patch.object(observer.os, 'geteuid', return_value=0), \
             patch.object(observer, 'baseline', return_value={}), \
             patch.object(observer, 'unit', return_value={'ActiveState': 'active', 'MainPID': '42'}), \
             patch.object(observer.keys, 'keyboard_for_service') as device:
            with self.assertRaisesRegex(ValueError, 'farpane_must_be_stopped'):
                observer.capture(argparse.Namespace(uid=1000, host_pid=123, seconds=30))
            device.assert_not_called()

    def test_wrong_unit_dropin_inactive_and_absent_pid_refused(self):
        native = {'ActiveState': 'inactive', 'MainPID': '0'}
        original = {'ActiveState': 'active', 'MainPID': '123',
                    'FragmentPath': str(observer.UNIT), 'DropInPaths': ''}
        self.assertEqual(observer.check_units(original, native), 123)
        for change in ({'FragmentPath': '/tmp/fake'}, {'DropInPaths': '/tmp/override'},
                       {'ActiveState': 'activating'}, {'MainPID': '0'}):
            with self.assertRaises(ValueError):
                observer.check_units({**original, **change}, native)

    def test_baseline_hash_and_during_read_changes_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'core'; path.write_bytes(b'known original')
            pins = {path: hashlib.sha256(path.read_bytes()).hexdigest()}
            with patch.object(observer, 'PINS', pins), patch.object(observer, 'fingerprint', return_value=(1,)):
                self.assertEqual(observer.baseline(), {path: (1,)})
                path.write_bytes(b'different core')
                with self.assertRaisesRegex(ValueError, 'baseline_mismatch'):
                    observer.baseline()
            path.write_bytes(b'known original')
            with patch.object(observer, 'PINS', pins), \
                 patch.object(observer, 'fingerprint', side_effect=[(1,), (2,)]):
                with self.assertRaisesRegex(ValueError, 'baseline_mismatch'):
                    observer.baseline()

    def test_untrusted_file_owner_mode_and_symlink_refused(self):
        for mode, uid in ((stat.S_IFLNK | 0o777, 0), (stat.S_IFREG | 0o666, 0),
                          (stat.S_IFREG | 0o644, 1000)):
            path = SimpleNamespace(lstat=lambda: SimpleNamespace(st_mode=mode, st_uid=uid))
            with self.assertRaisesRegex(ValueError, 'untrusted_baseline_file'):
                observer.fingerprint(path)

    def test_check_baseline_mode_never_enters_capture(self):
        with patch.object(observer.sys, 'argv', [str(CLI), '--check-baseline']), \
             patch.object(observer, 'baseline', return_value={}) as check, \
             patch.object(observer, 'capture') as capture, \
             patch('builtins.print'):
            observer.main()
            check.assert_called_once()
            capture.assert_not_called()


class ProcessIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.proc = self.root / '123'; self.proc.mkdir()
        self.lib = self.root / 'librustdesk.so'; self.lib.write_bytes(b'fixture')
        (self.proc / 'exe').symlink_to(observer.EXE)
        (self.proc / 'cmdline').write_bytes(os.fsencode(observer.EXE) + b'\0--server\0')
        (self.proc / 'stat').write_text('123 (fixture) S ' + '0 ' * 18 + '456')
        info = self.lib.stat()
        self.maps = f'1000-2000 r-xp 0 {os.major(info.st_dev):x}:{os.minor(info.st_dev):x} {info.st_ino} {self.lib}\n'
        (self.proc / 'maps').write_text(self.maps)
        p = patch.object(observer, 'Path', side_effect=lambda s: self.root if s == '/proc' else Path(s))
        p.start(); self.addCleanup(p.stop)
        p = patch.object(observer, 'LIB', self.lib); p.start(); self.addCleanup(p.stop)

    def check(self):
        return observer.process(123, os.getuid(), '--server')

    def test_valid_process_and_binary_alias(self):
        self.assertEqual(self.check(), 456)
        (self.proc / 'cmdline').write_bytes(b'/usr/bin/rustdesk\0--server\0')
        self.assertEqual(self.check(), 456)

    def test_wrong_uid_executable_role_and_extra_arguments(self):
        with self.assertRaises(ValueError):
            observer.process(123, os.getuid() + 1, '--server')
        for argv in (b'/tmp/other\0--server\0', b'/usr/bin/rustdesk\0--service\0',
                     b'/usr/bin/rustdesk\0--server\0extra\0'):
            (self.proc / 'cmdline').write_bytes(argv)
            with self.assertRaises(ValueError): self.check()
        (self.proc / 'exe').unlink(); (self.proc / 'exe').symlink_to('/tmp/other')
        with self.assertRaises(ValueError): self.check()

    def test_absent_deleted_or_different_library_mapping(self):
        wrong_inode = self.maps.split(); wrong_inode[4] = '0'
        for maps in ('', self.maps.rstrip() + ' (deleted)\n', ' '.join(wrong_inode)):
            (self.proc / 'maps').write_text(maps)
            with self.assertRaises(ValueError): self.check()


if __name__ == '__main__':
    unittest.main()
