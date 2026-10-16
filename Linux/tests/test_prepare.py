"""Regression: standard patches must apply inside a nested archive export."""
import importlib.util
import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('prepare', ROOT / 'Scripts/linux/prepare.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class PreparationTests(unittest.TestCase):
    def test_overlay_preserves_unknown_edits(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'Build/Linux') as temp:
            canonical = Path(temp) / 'canonical.rs'
            canonical.write_text('pub fn original() {}\n')
            target = Path(temp) / 'src/overlay.rs'
            digest = hashlib.sha256(canonical.read_bytes()).hexdigest()
            prepare.install_overlay(canonical, target, digest)
            prepare.install_overlay(canonical, target, digest)
            self.assertEqual(target.read_bytes(), canonical.read_bytes())
            target.write_text('user changes\n')
            with self.assertRaises(RuntimeError):
                prepare.install_overlay(canonical, target, digest)
            self.assertEqual(target.read_text(), 'user changes\n')

    def test_nested_export_patch_is_applied_and_idempotent(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'Build/Linux') as temp:
            outer = Path(temp)
            subprocess.run(['git', 'init', '-q', str(outer)], check=True)
            source = outer / 'Build/src/archive'
            source.mkdir(parents=True)
            target = source / 'file.txt'
            target.write_text('old\n')
            patch = outer / 'fix.patch'
            patch.write_text('diff --git a/file.txt b/file.txt\n'
                             '--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new\n')
            prepare.apply_patch(source, patch)
            self.assertEqual(target.read_text(), 'new\n')
            prepare.apply_patch(source, patch)
            self.assertEqual(target.read_text(), 'new\n')

    def test_conflicting_source_and_unknown_export_are_preserved(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'Build/Linux') as temp:
            source = Path(temp) / 'archive'
            source.mkdir()
            target = source / 'file.txt'
            target.write_text('user edit\n')
            patch = Path(temp) / 'fix.patch'
            patch.write_text('--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new\n')
            with self.assertRaises(subprocess.CalledProcessError):
                prepare.apply_patch(source, patch)
            with self.assertRaises(RuntimeError):
                prepare.export_git('rustdesk', Path(temp) / 'missing-reference', source)
            self.assertEqual(target.read_text(), 'user edit\n')


if __name__ == '__main__':
    unittest.main()
