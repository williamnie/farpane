"""Regressions for leaks hidden in binaries, compressed payloads and file names."""
import gzip
import hashlib
import io
from pathlib import Path
import re
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'packaging'))
from native_privacy import Scanner, rules


class PrivacyTests(unittest.TestCase):
    def scanner(self):
        return Scanner([('fixture', re.compile(b'fixture-private-host'))])

    def tar(self, name, data):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w') as archive:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        return output.getvalue()

    def test_binary_nul_bytes_do_not_hide_strings(self):
        scanner = self.scanner()
        scanner.inspect('core', b'\x7fELF\0\xfffixture-private-host\0')
        self.assertEqual(scanner.report()['result'], 'fail')

    def test_nested_compressed_archive(self):
        nested = gzip.compress(self.tar('core', b'\0fixture-private-host\0'))
        scanner = self.scanner()
        scanner.inspect('outer.tar.gz', gzip.compress(self.tar('inner.tar.gz', nested)))
        self.assertTrue(any('!core' in entry['file'] for entry in scanner.hits))

    def test_debian_ar_data_tar_is_scanned(self):
        data = gzip.compress(self.tar('usr/lib/core', b'fixture-private-host'))
        header = f'{"data.tar.gz/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(data):<10}`\n'.encode()
        scanner = self.scanner()
        scanner.inspect('candidate.deb', b'!<arch>\n' + header + data + b'\n' * (len(data) % 2))
        self.assertEqual(scanner.report()['result'], 'fail')

    def test_zip_file_name_and_content(self):
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w') as archive:
            archive.writestr('fixture-private-host.txt', 'clean')
        scanner = self.scanner()
        scanner.inspect('input.zip', output.getvalue())
        self.assertTrue(scanner.hits)
        self.assertNotIn('fixture-private-host', str(scanner.report()))

    def test_symlink_is_not_followed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'outside').write_text('fixture-private-host')
            (root / 'payload').mkdir()
            (root / 'payload/link').symlink_to('../outside')
            scanner = self.scanner()
            scanner.path(root / 'payload')
            self.assertFalse(scanner.hits)

    def test_invalid_rule_fails_without_revealing_value(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'rules'
            path.write_text('[fixture-private-host')
            with self.assertRaisesRegex(ValueError, 'private-rule-1') as error:
                rules(path)
            self.assertNotIn('fixture-private-host', str(error.exception))

    def test_truncated_ar_fails_closed(self):
        with self.assertRaises(ValueError):
            self.scanner().inspect('bad.deb', b'!<arch>\ntruncated')

    def test_clean_archive_passes(self):
        scanner = self.scanner()
        scanner.inspect('clean.tar.gz', gzip.compress(self.tar('core', b'\x7fELF\0public')))
        self.assertEqual(scanner.report()['result'], 'pass')

    def test_only_exact_pinned_corrupt_fixture_may_remain_opaque(self):
        data = b'\x1f\x8b\x08\x00' + b'fixture-private-host'
        with patch('native_privacy.OPAQUE_TEST_FIXTURES', {hashlib.sha256(data).hexdigest()}):
            scanner = self.scanner()
            scanner.inspect('fixture.bin', data)
            self.assertTrue(scanner.hits)  # Raw private strings are still rejected.
            self.assertEqual(len(scanner.opaque_fixtures), 1)
            with self.assertRaises((OSError, EOFError, zlib.error)):
                scanner.inspect('changed-fixture.bin', data + b'changed')

    def test_public_name_collision_requires_exact_path_and_bytes(self):
        data = b'fixture-private-host'
        with patch('native_privacy.PUBLIC_SOURCE_COLLISIONS', {'upstream/recipe': hashlib.sha256(data).hexdigest()}):
            scanner = self.scanner()
            scanner.inspect('archive!upstream/recipe', data)
            self.assertFalse(scanner.hits)
            self.assertEqual(len(scanner.public_source_collisions), 1)
            scanner.inspect('archive!upstream/recipe', data + b'changed')
            scanner.inspect('elsewhere', data)
            self.assertEqual(len(scanner.hits), 2)


if __name__ == '__main__':
    unittest.main()
