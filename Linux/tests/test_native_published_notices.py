"""Reject altered frozen source trees and Cargo-valid changes to real crates."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'Linux/packaging'))
import native_published_notices as notices


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True)+'\n')


class SnapshotBoundary(unittest.TestCase):
    def setUp(self):
        base = ROOT/'Build/Linux/published-notice-checks'
        base.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(dir=base)
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root/'app.rs').write_text('fn main() {}\n')
        self.sources = {'app.rs': notices.digest(self.root/'app.rs')}
        write_json(self.root/'binary-build-receipt.json', {'sources': self.sources})
        self.seal()

    def seal(self):
        files = {p.name: {'sha256': notices.digest(p), 'bytes': p.stat().st_size,
                         'executable': bool(p.stat().st_mode & 0o111)}
                 for p in self.root.iterdir() if p.name != 'source-manifest.json'}
        write_json(self.root/'source-manifest.json',
                   {'schema': 1, 'kind': 'farpane-native-source-snapshot', 'files': files})
        self.sha = notices.digest(self.root/'source-manifest.json')

    def check(self):
        return notices.verify_snapshot(self.root, self.sha, self.sources)

    def test_intact_snapshot(self):
        self.assertEqual(len(self.check()['files']), 2)

    def test_wrong_manifest_identity(self):
        with self.assertRaisesRegex(ValueError, 'manifest identity'):
            notices.verify_snapshot(self.root, '0'*64, self.sources)

    def test_changed_file_rejected(self):
        (self.root/'app.rs').write_text('changed\n')
        with self.assertRaisesRegex(ValueError, 'file inventory'):
            self.check()

    def test_extra_file_rejected(self):
        (self.root/'extra').write_text('extra\n')
        with self.assertRaisesRegex(ValueError, 'file inventory'):
            self.check()

    def test_resealed_source_still_must_match_compilation(self):
        (self.root/'app.rs').write_text('changed\n')
        self.seal()
        with self.assertRaisesRegex(ValueError, 'Compiled canonical source'):
            self.check()

    def test_different_application_receipt_rejected(self):
        write_json(self.root/'binary-build-receipt.json', {'sources': {'app.rs': '0'*64}})
        self.seal()
        with self.assertRaisesRegex(ValueError, 'different application sources'):
            self.check()

    def test_escaping_symlink_rejected(self):
        (self.root/'escape').symlink_to('/etc/passwd')
        with self.assertRaisesRegex(ValueError, 'symlink escapes'):
            self.check()


@unittest.skipUnless(os.environ.get('FARPANE_NOTICE_TEST_SNAPSHOT'), 'requires an existing frozen source snapshot')
class RealVendoredProofs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.snapshot = Path(os.environ['FARPANE_NOTICE_TEST_SNAPSHOT']).resolve(strict=True)
        if not cls.snapshot.is_relative_to(ROOT/'Build/Linux/source-bundles'):
            raise ValueError('Test inputs must be under Build/Linux/source-bundles')
        cls.pins = json.loads((cls.snapshot/'Linux/native-published-notices.json').read_text())['packages']

    def check_cases(self, mutation=None, *, refresh_checksum=False):
        for pin in self.pins:
            with self.subTest(package=pin['name']), tempfile.TemporaryDirectory(
                    dir=ROOT/'Build/Linux/published-notice-checks') as temporary:
                root = Path(temporary)/'crate'
                shutil.copytree(self.snapshot/pin['source_snapshot_package'], root)
                tree = json.loads((self.snapshot/pin['tree_path']).read_text())
                if mutation:
                    mutation(root)
                if refresh_checksum:
                    path = root/'.cargo-checksum.json'
                    data = json.loads(path.read_text())
                    data['files'] = {p.relative_to(root).as_posix(): notices.digest(p)
                                     for p in root.rglob('*') if p.is_file() and p != path}
                    write_json(path, data)
                if mutation:
                    with self.assertRaises(ValueError):
                        notices.verify_crate(root, pin, tree, vendor=True)
                else:
                    self.assertEqual(notices.verify_crate(root, pin, tree, vendor=True),
                                     len(pin['published_files']))

    def test_original_published_files(self):
        self.check_cases()

    def test_checksum_required(self):
        self.check_cases(lambda root: (root/'.cargo-checksum.json').unlink())

    def test_source_edit_rejected_even_with_new_cargo_checksums(self):
        self.check_cases(lambda root: (root/'src/lib.rs').write_text('changed\n'), refresh_checksum=True)

    def test_manifest_edit_rejected_even_with_new_cargo_checksums(self):
        self.check_cases(lambda root: (root/'Cargo.toml').write_text('changed\n'), refresh_checksum=True)

    def test_added_source_rejected_even_with_new_cargo_checksums(self):
        self.check_cases(lambda root: (root/'extra.rs').write_text('extra\n'), refresh_checksum=True)

    def test_removed_source_rejected_even_with_new_cargo_checksums(self):
        self.check_cases(lambda root: (root/'src/lib.rs').unlink(), refresh_checksum=True)

    def test_symlink_rejected(self):
        self.check_cases(lambda root: (root/'unexpected').symlink_to('src/lib.rs'))


if __name__ == '__main__':
    unittest.main()
