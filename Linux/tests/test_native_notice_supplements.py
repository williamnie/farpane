"""Exact source revision and notice integrity must survive offline collection."""
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'packaging'))
import native_notice_supplements as notices


def entry(data):
    return {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
            'git_blob_sha1': hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()}


class UpstreamNoticeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'Build/Linux/crate'
        self.source.mkdir(parents=True)
        self.manifest = self.source / 'Cargo.toml'
        self.manifest.write_text('[package]\nname="example"\nversion="1.0"\n')
        (self.source / 'src').mkdir()
        (self.source / 'src/lib.rs').write_text('pub fn example() {}\n')
        self.revision = 'a' * 40
        self.vcs = self.source / '.cargo_vcs_info.json'
        self.vcs.write_text(json.dumps({'git': {'sha1': self.revision}, 'path_in_vcs': 'crate'}))
        self.notice = self.root / 'Linux/notices/upstream/owner/repo' / self.revision / 'LICENSE'
        self.notice.parent.mkdir(parents=True)
        self.notice.write_text('Synthetic notice bytes for integrity tests.\n')
        self.tree = self.root / 'output'
        self.pin = {'name': 'example', 'version': '1.0', 'full_package_notice_located': True,
                    'upstream': {'repository': 'owner/repo', 'revision': self.revision,
                        'cargo_vcs_info_sha256': notices.digest(self.vcs),
                        'source_bindings': [
                            {'kind': 'original_manifest', 'local_path': 'Cargo.toml',
                             'upstream_path': 'crate/Cargo.toml', **entry(self.manifest.read_bytes())},
                            {'kind': 'library_source', 'local_path': 'src/lib.rs',
                             'upstream_path': 'crate/src/lib.rs', **entry((self.source/'src/lib.rs').read_bytes())}],
                        'files': [{'path': str(self.notice.relative_to(self.root)), 'upstream_path': 'LICENSE',
                                   'url': f'https://raw.githubusercontent.com/owner/repo/{self.revision}/LICENSE',
                                   'scope': 'package_license_text', **entry(self.notice.read_bytes())}]}}
        self.root_patch = patch.object(notices, 'ROOT', self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)

    def collect(self, pin=None):
        return notices.upstream_materials(pin or self.pin, self.manifest, self.source, self.tree)

    def test_exact_bytes_are_retained(self):
        result = self.collect()
        self.assertEqual(len(result), 1)
        self.assertEqual((self.tree/result[0]['material']).read_bytes(), self.notice.read_bytes())

    def test_revision_mismatch_rejected(self):
        self.pin['upstream']['revision'] = 'b' * 40
        with self.assertRaisesRegex(ValueError, 'revision differs'):
            self.collect()

    def test_dirty_source_rejected(self):
        self.vcs.write_text(json.dumps({'git': {'sha1': self.revision, 'dirty': True}}))
        self.pin['upstream']['cargo_vcs_info_sha256'] = notices.digest(self.vcs)
        with self.assertRaisesRegex(ValueError, 'revision differs'):
            self.collect()

    def test_modified_manifest_rejected(self):
        self.manifest.write_text('other source')
        with self.assertRaises(ValueError):
            self.collect()

    def test_modified_library_rejected(self):
        (self.source/'src/lib.rs').write_text('other source')
        with self.assertRaises(ValueError):
            self.collect()

    def test_vcs_package_path_mismatch_rejected(self):
        self.pin['upstream']['source_bindings'][0]['upstream_path'] = 'another/Cargo.toml'
        with self.assertRaisesRegex(ValueError, 'location differs'):
            self.collect()

    def test_both_source_bindings_required(self):
        self.pin['upstream']['source_bindings'].pop()
        with self.assertRaisesRegex(ValueError, 'needs manifest and library'):
            self.collect()

    def test_modified_notice_rejected(self):
        self.notice.write_text('changed')
        with self.assertRaises(ValueError):
            self.collect()

    def test_git_blob_mismatch_rejected(self):
        self.pin['upstream']['files'][0]['git_blob_sha1'] = 'b' * 40
        with self.assertRaisesRegex(ValueError, 'Git blob differs'):
            self.collect()

    def test_wrong_origin_url_rejected(self):
        self.pin['upstream']['files'][0]['url'] = 'https://example.com/LICENSE'
        with self.assertRaisesRegex(ValueError, 'location or scope'):
            self.collect()

    def test_path_traversal_rejected(self):
        for field in ('path', 'upstream_path'):
            with self.subTest(field=field):
                pin = copy.deepcopy(self.pin)
                pin['upstream']['files'][0][field] = '../LICENSE'
                with self.assertRaisesRegex(ValueError, 'Invalid upstream notice path'):
                    self.collect(pin)

    def test_notice_symlink_rejected(self):
        target = self.notice.with_name('saved')
        self.notice.rename(target)
        self.notice.symlink_to(target.name)
        with self.assertRaises(ValueError):
            self.collect()

    def test_parent_symlink_rejected(self):
        parent = self.notice.parent
        target = parent.with_name('saved')
        parent.rename(target)
        parent.symlink_to(target.name, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.collect()

    def test_reference_alone_cannot_close_notice(self):
        self.pin['upstream']['files'][0]['scope'] = 'package_declaration_context'
        with self.assertRaisesRegex(ValueError, 'lacks its notice text'):
            self.collect()


if __name__ == '__main__':
    unittest.main()
