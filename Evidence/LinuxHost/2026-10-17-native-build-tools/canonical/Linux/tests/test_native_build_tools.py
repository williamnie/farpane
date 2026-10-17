"""Tool preparation rejects damaged caches and SDKs without repairing them."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'packaging'))
import native_build_tools as tools


class ToolIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / 'cache'
        self.cache.mkdir()
        self.good = b'fixed public tool payload'
        self.pin = {'url': 'https://example.invalid/tool', 'filename': 'tool',
                    'algorithm': 'sha256', 'digest': hashlib.sha256(self.good).hexdigest(),
                    'max_bytes': 1024}
        self.lock = {'tools': {'tool': self.pin}}

    def test_offline_reuse_requires_exact_bytes(self):
        path = self.cache / 'tool'
        path.write_bytes(self.good)
        result = tools.fetch(self.lock, self.cache, offline=True)
        self.assertTrue(result['tool']['cache_reused'])
        path.write_bytes(b'damaged')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            tools.fetch(self.lock, self.cache, offline=True)
        self.assertEqual(path.read_bytes(), b'damaged')

    def test_missing_offline_tool_does_not_create_a_candidate(self):
        with self.assertRaisesRegex(ValueError, 'Offline cache missing'):
            tools.fetch(self.lock, self.cache, offline=True)
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_cached_symlink_does_not_read_or_replace_external_file(self):
        outside = self.root / 'retained'
        outside.write_bytes(self.good)
        (self.cache / 'tool').symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'linked cached tool'):
            tools.fetch(self.lock, self.cache, offline=True)
        self.assertEqual(outside.read_bytes(), self.good)
        self.assertTrue((self.cache / 'tool').is_symlink())

    def test_sdk_inventory_rejects_extra_and_modified_files(self):
        sdk = self.root / 'sdk'
        sdk.mkdir()
        binary = sdk / 'compiler'
        binary.write_bytes(self.good)
        lock = self.root / 'lock.json'
        lock.write_text('{}')
        receipt = {'schema': 1, 'kind': 'farpane-rust-sdk', 'lock_sha256': tools.digest(lock),
                   'files': tools.inventory(sdk)}
        (sdk / 'toolchain-receipt.json').write_text(json.dumps(receipt))
        tools.verify_sdk(sdk, lock)
        extra = sdk / 'unexpected-library'
        extra.write_bytes(b'extra')
        with self.assertRaisesRegex(ValueError, 'inventory changed'):
            tools.verify_sdk(sdk, lock)
        extra.unlink()
        binary.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'inventory changed'):
            tools.verify_sdk(sdk, lock)
        self.assertEqual(binary.read_bytes(), b'changed')

    def test_sdk_link_may_not_escape_prefix(self):
        sdk = self.root / 'sdk'
        sdk.mkdir()
        retained = self.root / 'retained'
        retained.write_bytes(self.good)
        (sdk / 'library').symlink_to('../retained')
        with self.assertRaisesRegex(ValueError, 'Unsafe SDK symlink'):
            tools.inventory(sdk)
        self.assertEqual(retained.read_bytes(), self.good)


if __name__ == '__main__':
    unittest.main()
