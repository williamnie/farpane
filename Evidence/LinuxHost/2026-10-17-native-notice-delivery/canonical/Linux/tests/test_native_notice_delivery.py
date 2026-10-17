"""Package the original notice evidence without broadening its claims."""
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'packaging'))
import native_notice_delivery as delivery


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True)+'\n')


def entry(path):
    return {'bytes': path.stat().st_size, 'sha256': delivery.digest(path)}


class NoticeDeliveryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.sources = {'Linux/gui/src/main.rs': 'a'*64}
        self.audit = self.root/'audit/report.json'
        record = self.root/'audit/materials/Build/Linux/native-build.json'
        write(record, {'sources': self.sources})
        notice = self.root/'audit/materials/dependency/LICENSE'
        notice.parent.mkdir(parents=True)
        notice.write_text('original notice\n')
        self.audited_binaries = {'native-core': 'b'*64, 'native-gui': 'c'*64}
        write(self.audit, {'binary_sha256': self.audited_binaries, 'cargo_packages': [{'name': 'example'}],
            'issues': [{'package': 'example', 'kind': 'missing_manifest_license_declaration'}],
            'materials': {'Build/Linux/native-build.json': entry(record), 'dependency/LICENSE': entry(notice)}})
        self.supplement = self.root/'supplements'
        write(self.supplement/'notice-pins.json', {'schema': 1, 'packages': []})
        self.pins = delivery.digest(self.supplement/'notice-pins.json')
        write(self.supplement/'report.json', {'baseline_audit_sha256': delivery.digest(self.audit),
            'pins_sha256': self.pins, 'binary_sha256': self.audited_binaries,
            'full_package_notice_locations_added': 0,
            'baseline_records_without_full_notice_location_followup': 1})
        (self.supplement/'SHA256SUMS').write_text(''.join(delivery.digest(p)+'  '+p.name+'\n'
            for p in sorted(self.supplement.iterdir())))
        self.target = self.root/'delivery'

    def assemble(self, target=None):
        return delivery.assemble(self.audit, self.supplement, self.sources, self.pins, target or self.target)

    def verify(self, sources=None):
        return delivery.verify(self.target, sources or self.sources, self.pins)

    def test_original_bytes_and_unresolved_records_retained(self):
        manifest = self.assemble()
        self.assertEqual((self.target/'inventory/materials/dependency/LICENSE').read_text(), 'original notice\n')
        self.assertEqual(manifest['original_inventory_records'], 1)
        self.assertEqual(manifest['records_without_full_notice_followup'], 1)
        self.assertFalse(manifest['complete_license_source_audit'])
        self.assertEqual(manifest['audited_binary_sha256'], self.audited_binaries)

    def test_repeated_collection_has_same_identity(self):
        self.assertEqual(self.assemble(), self.assemble(self.root/'another'))

    def test_different_application_sources_rejected(self):
        self.assemble()
        with self.assertRaises(ValueError):
            self.verify({'Linux/gui/src/main.rs': 'd'*64})

    def test_different_notice_pins_rejected(self):
        self.assemble()
        with self.assertRaises(ValueError):
            delivery.verify(self.target, self.sources, 'd'*64)

    def test_changed_material_rejected(self):
        self.assemble()
        (self.target/'inventory/materials/dependency/LICENSE').write_text('changed')
        with self.assertRaises(ValueError):
            self.verify()

    def test_added_file_rejected(self):
        self.assemble()
        (self.target/'unexpected').write_text('extra')
        with self.assertRaises(ValueError):
            self.verify()

    def test_symlink_rejected(self):
        self.assemble()
        path = self.target/'inventory/materials/dependency/LICENSE'
        path.unlink()
        path.symlink_to(self.root/'audit/materials/dependency/LICENSE')
        with self.assertRaises(ValueError):
            self.verify()

    def test_corrupt_inventory_input_rejected(self):
        (self.root/'audit/materials/dependency/LICENSE').write_text('changed')
        with self.assertRaises(ValueError):
            self.assemble()

    def test_corrupt_supplement_input_rejected(self):
        (self.supplement/'notice-pins.json').write_text('changed')
        with self.assertRaises(ValueError):
            self.assemble()

    def frozen_project(self):
        project = self.root/'snapshot'
        self.assemble(project/'native-dependencies/notice-delivery')
        pins = project/'Linux/native-notice-supplements.json'
        pins.parent.mkdir(parents=True)
        shutil.copyfile(self.supplement/'notice-pins.json', pins)
        frozen = project/'native-dependencies/notice-delivery/manifest.json'
        write(project/'source-manifest.json', {'files': {
            'native-dependencies/notice-delivery/manifest.json': entry(frozen)}})
        return project

    def test_frozen_delivery_works_without_original_caches(self):
        project = self.frozen_project()
        shutil.rmtree(self.root/'audit')
        shutil.rmtree(self.supplement)
        result = delivery.prepare(project, self.sources, self.target)
        self.assertEqual(result, self.verify())
        self.assertFalse((project/'Build').exists())

    def test_snapshot_binding_required(self):
        project = self.frozen_project()
        write(project/'source-manifest.json', {'files': {}})
        with self.assertRaisesRegex(ValueError, 'does not bind'):
            delivery.prepare(project, self.sources, self.target)

    def test_unsafe_paths_rejected(self):
        for value in ('../escape', '/etc/passwd', 'a/../b', 'a//b', 'a\\b', 'a\nb'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                delivery.relative(value)


if __name__ == '__main__':
    unittest.main()
