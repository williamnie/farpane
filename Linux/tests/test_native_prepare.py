"""Native staging must preserve unrelated work and never follow build symlinks."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('native_prepare', ROOT / 'Scripts/linux/prepare-native.py')
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class NativeStageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / 'Build/Linux')
        self.root = Path(self.temp.name)
        stage.ROOT = self.root
        stage.BUILD = self.root / 'Build/Linux'
        stage.MANIFEST = stage.BUILD / 'native-source-map.json'
        stage.BUILD.mkdir(parents=True)
        self.source = self.root / 'Linux/gui/src/main.rs'
        self.source.parent.mkdir(parents=True)
        self.source.write_text('first\n')

    def tearDown(self):
        self.temp.cleanup()

    def test_known_previous_version_updates_but_unrelated_edit_is_preserved(self):
        stage.main()
        self.source.write_text('second\n')
        stage.main()
        target = stage.BUILD / 'gui/src/main.rs'
        self.assertEqual(target.read_text(), 'second\n')
        target.write_text('another owner\n')
        self.source.write_text('third\n')
        with self.assertRaises(RuntimeError):
            stage.main()
        self.assertEqual(target.read_text(), 'another owner\n')

    def test_symlink_target_is_never_followed(self):
        outside = self.root / 'unrelated'
        outside.write_text('preserve me\n')
        target = stage.BUILD / 'gui/src/main.rs'
        target.parent.mkdir(parents=True)
        target.symlink_to(outside)
        with self.assertRaises(RuntimeError):
            stage.main()
        self.assertEqual(outside.read_text(), 'preserve me\n')

    def test_entire_operation_is_validated_before_any_copy(self):
        stage.main()
        another = self.source.parent / 'other.rs'
        another.write_text('new\n')
        (stage.BUILD / 'gui/src/main.rs').write_text('unrelated edit\n')
        with self.assertRaises(RuntimeError):
            stage.main()
        self.assertFalse((stage.BUILD / 'gui/src/other.rs').exists())

    def test_manifest_cannot_escape_staging_root(self):
        stage.MANIFEST.write_text('{"../../unrelated": "bad"}')
        with self.assertRaises(RuntimeError):
            stage.main()

    def test_read_only_check_catches_changes_without_repairing_them(self):
        files = self.root / 'Linux/native/files/Cargo.lock'
        files.parent.mkdir(parents=True)
        files.write_text('pinned-lock\n')
        stage.main()
        stage.main(check=True)
        manifest = stage.MANIFEST.read_bytes()
        target = stage.BUILD / 'native/files/Cargo.lock'
        target.write_text('unknown build edit\n')
        with self.assertRaises(RuntimeError):
            stage.main(check=True)
        self.assertEqual(target.read_text(), 'unknown build edit\n')
        self.assertEqual(stage.MANIFEST.read_bytes(), manifest)
        target.write_text('pinned-lock\n')
        files.write_text('updated pin\n')
        with self.assertRaises(RuntimeError):
            stage.main(check=True)
        self.assertEqual(target.read_text(), 'pinned-lock\n')
        self.assertEqual(stage.MANIFEST.read_bytes(), manifest)


if __name__ == '__main__':
    unittest.main()
