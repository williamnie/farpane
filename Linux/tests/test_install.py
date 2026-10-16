"""Installer acceptance: preserve existing releases and refuse tampered input."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('installer', ROOT / 'Scripts/linux/install-app.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
system_spec = importlib.util.spec_from_file_location('system_installer', ROOT / 'Scripts/linux/install-system.py')
system_installer = importlib.util.module_from_spec(system_spec)
system_spec.loader.exec_module(system_installer)


def artifact(path, name):
    path.mkdir()
    (path / 'farpane').write_text(name)
    (path / 'manifest.json').write_text(json.dumps({
        'artifact_id': name, 'stage': 'test fixture',
        'features': ['flutter', 'hwcodec', 'drm', 'farpane-linux'],
        'files': [{'path': 'farpane', 'sha256': hashlib.sha256(name.encode()).hexdigest()}],
    }))
    return path


class InstallTests(unittest.TestCase):
    def test_system_staging_is_inactive_and_preserves_old_release_and_foreign_unit(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'Build/Linux') as temporary:
            root = Path(temporary)
            source = artifact(root / 'one', 'farpane-system-one')
            second = artifact(root / 'two', 'farpane-system-two')
            base, units = root / 'opt/farpane', root / 'units'
            first = system_installer.stage(source, base, units)
            system_installer.stage(source, base, units)
            result = system_installer.stage(second, base, units)
            self.assertFalse(result['started'])
            self.assertFalse(result['enabled'])
            self.assertFalse(result['daemon_reload'])
            self.assertEqual(result['previous'], 'releases/farpane-system-one')
            self.assertEqual((Path(first['installed']) / 'farpane').read_text(), 'farpane-system-one')
            self.assertEqual((base / 'farpane').read_text(), 'farpane-system-two')
            unit = units / 'farpane.service'
            unit.write_text('existing user service')
            with self.assertRaises(ValueError):
                system_installer.stage(source, base, units)
            self.assertEqual(unit.read_text(), 'existing user service')
            self.assertEqual((base / 'farpane').read_text(), 'farpane-system-two')

    def test_install_and_update_preserve_previous_release(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'Build/Linux') as temporary:
            root = Path(temporary)
            home = root / 'desktop user'
            first = artifact(root / 'one', 'farpane-one')
            second = artifact(root / 'two', 'farpane-two')
            one = installer.install(first, home)
            installer.install(first, home)
            two = installer.install(second, home)
            self.assertEqual(Path(one['installed'], 'farpane').read_text(), 'farpane-one')
            self.assertEqual(Path(two['executable']).read_text(), 'farpane-two')
            self.assertEqual(two['previous'], 'farpane-one')
            self.assertFalse(two['started'])
            self.assertFalse((home / '.config/rustdesk').exists())

    def test_tampered_bundle_and_unmanaged_launcher_are_preserved(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'Build/Linux') as temporary:
            root = Path(temporary)
            source = artifact(root / 'app', 'farpane-test')
            home = root / 'user'
            (source / 'farpane').write_text('modified')
            with self.assertRaises(ValueError):
                installer.install(source, home)
            self.assertFalse(home.exists())
            (source / 'farpane').write_text('farpane-test')
            launcher = home / '.local/share/applications/org.farpane.FarPane.desktop'
            launcher.parent.mkdir(parents=True)
            launcher.write_text('user launcher')
            with self.assertRaises(ValueError):
                installer.install(source, home)
            self.assertEqual(launcher.read_text(), 'user launcher')


if __name__ == '__main__':
    unittest.main()
