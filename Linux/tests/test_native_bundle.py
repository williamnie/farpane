"""Adversarial integrity checks, confined to a caller-selected temporary tree."""
from pathlib import Path
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'packaging'))
import native_bundle as bundle


class BundleIntegrity(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[2]/'Build/Linux')
        self.root=Path(self.temporary.name)/'release';self.root.mkdir(mode=0o755)
        for name in bundle.REQUIRED-{'lib/libdrmtap.so.0'}:
            path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True)
            path.write_text('synthetic test content\n')
            path.chmod(0o755 if name in ('farpane','libexec/farpane-core') else 0o644)
        library=self.root/'lib/libdrmtap.so.0.5.8';library.parent.mkdir(exist_ok=True)
        library.write_text('synthetic test library');library.chmod(0o755)
        (self.root/'lib/libdrmtap.so.0').symlink_to(library.name)
        for path in self.root.rglob('*'):
            if path.is_dir():path.chmod(0o755)
        self.manifest=bundle.seal(self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def rewrite(self,change):
        document=json.loads((self.root/'manifest.json').read_text());change(document)
        (self.root/'manifest.json').write_text(json.dumps(document))

    def rejected(self):
        with self.assertRaises((ValueError,OSError)):bundle.verify(self.root)

    def test_exact_bundle(self):
        self.assertEqual(bundle.verify(self.root),self.manifest)

    def test_changed_binary(self):
        (self.root/'farpane').write_text('replaced executable');self.rejected()

    def test_added_file(self):
        (self.root/'unexpected').write_text('unlisted');self.rejected()

    def test_duplicate_entry(self):
        self.rewrite(lambda m:m['files'].append(m['files'][0]));self.rejected()

    def test_path_traversal(self):
        for name in ('../escape','/etc/passwd','a/../b','a//b','a\\b','a\nb'):
            with self.subTest(name=name):
                with self.assertRaises(ValueError):bundle.relative_path(name)

    def test_external_symlink(self):
        alias=self.root/'lib/libdrmtap.so.0';alias.unlink();alias.symlink_to('/etc/passwd');self.rejected()

    def test_directory_symlink(self):
        directory=self.root/'share';directory.rename(self.root/'hidden-share')
        directory.symlink_to('hidden-share');self.rejected()

    def test_writable_binary(self):
        (self.root/'farpane').chmod(0o777);self.rejected()

    def test_writable_directory(self):
        (self.root/'libexec').chmod(0o777);self.rejected()

    def test_hardlink(self):
        os.link(self.root/'farpane',Path(self.temporary.name)/'external-link');self.rejected()

    def test_fifo(self):
        os.mkfifo(self.root/'pipe');self.rejected()

    def test_manifest_symlink(self):
        document=self.root/'manifest.json';document.rename(Path(self.temporary.name)/'manifest.json')
        document.symlink_to('../manifest.json');self.rejected()

    def test_identity(self):
        self.rewrite(lambda m:m.update(artifact_id='farpane-native-dev-tampered'));self.rejected()

    def test_promoted_acceptance(self):
        self.rewrite(lambda m:m.update(runtime_ready=True));self.rejected()

    def test_missing_required_even_if_resealed(self):
        (self.root/'libexec/farpane-core').unlink();(self.root/'manifest.json').unlink()
        with self.assertRaises(ValueError):bundle.seal(self.root)


if __name__=='__main__':unittest.main()
