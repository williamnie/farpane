from pathlib import Path
import importlib.util
import plistlib
import subprocess
import tempfile
from types import SimpleNamespace
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "app_registration", ROOT / "Scripts/register-installed-app.py"
)
REGISTRATION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REGISTRATION)


def record(path, identifier=REGISTRATION.BUNDLE_ID):
    return f"----------------\npath: {path} (0x1234)\nidentifier: {identifier}\n"


class AppRegistrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.installed = Path(self.directory.name) / "Applications/FarPane.app"
        (self.installed / "Contents").mkdir(parents=True)
        self.write_info(REGISTRATION.BUNDLE_ID)

    def write_info(self, identifier):
        (self.installed / "Contents/Info.plist").write_bytes(
            plistlib.dumps({"CFBundleIdentifier": identifier})
        )

    def test_parser_limits_cleanup_to_exact_product_and_preserves_spaces(self):
        dump = (
            record(self.installed)
            + record("/tmp/Release Builds/Intel/FarPane.app")
            + record("/tmp/Release Builds/Intel/FarPane.app")
            + record("/Applications/Unrelated.app", "com.example.viewer")
            + record("/tmp/Host.app", REGISTRATION.BUNDLE_ID + ".host-agent")
        )
        self.assertEqual(
            REGISTRATION.registered_paths(dump),
            [self.installed.resolve(), Path("/tmp/Release Builds/Intel/FarPane.app").resolve()],
        )

    def test_repair_keeps_installed_app_and_checks_result_after_unregistering(self):
        duplicate = Path(self.directory.name) / "Intel Builds/FarPane.app"
        calls = []
        dumps = iter([record(duplicate) + record(self.installed), record(self.installed)])

        def run(args, **kwargs):
            calls.append(args)
            if args[-1] == "-dump":
                return SimpleNamespace(stdout=next(dumps), returncode=0)
            return SimpleNamespace(stdout="", returncode=0)

        self.assertEqual(
            REGISTRATION.register_installed_app(self.installed, run), [duplicate.resolve()]
        )
        self.assertEqual(calls[0], ["codesign", "--verify", "--deep", "--strict", str(self.installed.resolve())])
        self.assertEqual(
            [args for args in calls if "-u" in args],
            [[REGISTRATION.LSREGISTER, "-u", str(duplicate.resolve())]],
        )
        self.assertEqual(calls[-2], [REGISTRATION.LSREGISTER, "-f", str(self.installed.resolve())])
        self.assertEqual(calls[-1], [REGISTRATION.LSREGISTER, "-dump"])

    def test_wrong_bundle_and_invalid_signature_never_mutate_registrations(self):
        calls = []

        def reject_signature(args, **kwargs):
            calls.append(args)
            raise subprocess.CalledProcessError(1, args)

        self.write_info("com.example.other")
        with self.assertRaises(ValueError):
            REGISTRATION.register_installed_app(self.installed, reject_signature)
        self.assertEqual(calls, [])
        self.write_info(REGISTRATION.BUNDLE_ID)
        with self.assertRaises(subprocess.CalledProcessError):
            REGISTRATION.register_installed_app(self.installed, reject_signature)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "codesign")

    def test_retained_duplicate_is_reported_even_if_commands_succeeded(self):
        dump = record(self.installed) + record("/tmp/Stale/FarPane.app")

        def run(args, **kwargs):
            return SimpleNamespace(stdout=dump if args[-1] == "-dump" else "", returncode=0)

        with self.assertRaisesRegex(RuntimeError, "did not converge"):
            REGISTRATION.register_installed_app(self.installed, run)

    def test_malformed_matching_record_fails_before_any_unregister(self):
        calls = []

        def run(args, **kwargs):
            calls.append(args)
            return SimpleNamespace(
                stdout=f"identifier: {REGISTRATION.BUNDLE_ID}\npath: invalid\n", returncode=0
            )

        with self.assertRaises(ValueError):
            REGISTRATION.register_installed_app(self.installed, run)
        self.assertFalse(any("-u" in args or "-f" in args for args in calls))


if __name__ == "__main__":
    unittest.main()
