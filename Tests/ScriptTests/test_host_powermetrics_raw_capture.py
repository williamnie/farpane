import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "Scripts/sample-farpane-host-powermetrics.py"
SPEC = importlib.util.spec_from_file_location(
    "sample_farpane_host_powermetrics", SCRIPT_PATH
)
assert SPEC is not None and SPEC.loader is not None
CAPTURE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CAPTURE
SPEC.loader.exec_module(CAPTURE)


class HostPowermetricsRawCaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(dir=REPO_ROOT)
        self.root = Path(self.temporary_directory.name)
        self.prefix = self.root / "battery-run"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def request(self, duration: int = 2, mode: str = "smoke"):
        return CAPTURE.validate_request(
            "battery-active",
            str(duration),
            str(self.prefix),
            "123",
            mode,
        )

    def test_acceptance_and_smoke_duration_contracts(self) -> None:
        acceptance = CAPTURE.validate_request(
            "battery-idle", "600", str(self.prefix), "123", "acceptance"
        )
        smoke = self.request()

        self.assertEqual(acceptance.duration_seconds, 600)
        self.assertEqual(acceptance.sample_mode, "acceptance")
        self.assertEqual(smoke.duration_seconds, 2)
        for duration, mode in (("599", "acceptance"), ("1801", "acceptance"), ("61", "smoke")):
            with self.assertRaises(CAPTURE.CaptureError):
                CAPTURE.validate_request(
                    "battery-idle", duration, str(self.prefix), "123", mode
                )

    def test_rejects_unknown_scenario_relative_or_symlink_parent_and_bad_pid(self) -> None:
        with self.assertRaises(CAPTURE.CaptureError):
            CAPTURE.validate_request(
                "battery-baseline", "600", str(self.prefix), "123", "acceptance"
            )
        with self.assertRaises(CAPTURE.CaptureError):
            CAPTURE.validate_request(
                "battery-idle", "600", "relative/run", "123", "acceptance"
            )
        linked = self.root / "linked"
        linked.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(CAPTURE.CaptureError):
            CAPTURE.validate_request(
                "battery-idle", "600", str(linked / "run"), "123", "acceptance"
            )
        with self.assertRaises(CAPTURE.CaptureError):
            CAPTURE.validate_request(
                "battery-idle", "600", str(self.prefix), "1", "acceptance"
            )

    def test_rejects_group_or_world_writable_output_parent(self) -> None:
        unsafe = self.root / "unsafe"
        unsafe.mkdir(mode=0o777)
        unsafe.chmod(0o777)
        with self.assertRaisesRegex(CAPTURE.CaptureError, "group/world writable"):
            CAPTURE.validate_request(
                "battery-idle",
                "600",
                str(unsafe / "run"),
                "123",
                "acceptance",
            )

    def test_requires_existing_root_privilege_but_never_invokes_sudo(self) -> None:
        with self.assertRaisesRegex(CAPTURE.CaptureError, "never invokes sudo"):
            CAPTURE.require_superuser(501)
        CAPTURE.require_superuser(0)

        command = CAPTURE.build_powermetrics_command(self.request())
        self.assertEqual(command[0], "/usr/bin/powermetrics")
        self.assertIn("battery,cpu_power,thermal", command)
        self.assertIn("plist", command)
        self.assertNotIn("sudo", " ".join(command).lower())
        self.assertNotIn("tasks", command)
        self.assertNotIn("--show-process-energy", command)

    def test_cli_fails_closed_without_root_and_publishes_nothing(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("non-root CLI boundary requires a non-root test process")
        completed = subprocess.run(
            [
                sys.executable,
                str(SCRIPT_PATH),
                "battery-idle",
                "1",
                str(self.prefix),
                str(os.getpid()),
            ],
            env={**os.environ, "FARPANE_HOST_POWER_SAMPLE_MODE": "smoke"},
            check=False,
            capture_output=True,
            text=True,
        )
        raw_path, metadata_path = CAPTURE.output_paths(self.prefix)
        self.assertEqual(completed.returncode, 2)
        self.assertIn("never invokes sudo", completed.stderr)
        self.assertFalse(raw_path.exists())
        self.assertFalse(metadata_path.exists())

    def test_battery_preflight_requires_explicit_battery_power(self) -> None:
        def completed(stdout: str, returncode: int = 0):
            def runner(*_args, **_kwargs):
                return subprocess.CompletedProcess([], returncode, stdout, "")

            return runner

        self.assertTrue(
            CAPTURE.battery_power_is_active(
                completed("Now drawing from 'Battery Power'\n")
            )
        )
        self.assertFalse(
            CAPTURE.battery_power_is_active(completed("Now drawing from 'AC Power'\n"))
        )
        self.assertFalse(CAPTURE.battery_power_is_active(completed("", 1)))

    def test_hashes_exact_single_link_farpane_executable_and_detects_change(self) -> None:
        executable = self.root / "FarPane"
        executable.write_bytes(b"first-build")
        before = CAPTURE.hash_open_executable(executable)
        self.assertEqual(before.process_name, "FarPane")
        self.assertEqual(
            before.sha256,
            "9d8940c2a69e06a533bb7f9ba9b5cfe518fe4a06174dc83d7dc441adeebd5b0f",
        )
        executable.write_bytes(b"second-build")
        after = CAPTURE.hash_open_executable(executable)
        with self.assertRaises(CAPTURE.CaptureError):
            CAPTURE.require_same_executable(before, after)

        wrong_name = self.root / "python"
        wrong_name.write_bytes(b"binary")
        with self.assertRaises(CAPTURE.CaptureError):
            CAPTURE.hash_open_executable(wrong_name)

    def test_runs_fixture_command_without_parsing_plist_schema(self) -> None:
        fake = self.root / "fake-powermetrics"
        fake.write_text("#!/bin/sh\nprintf 'plist-one\\0plist-two\\0'\n", encoding="utf-8")
        fake.chmod(0o755)
        raw = self.root / "raw.partial"
        error = self.root / "stderr.partial"

        status = CAPTURE.run_powermetrics(
            [str(fake)], raw, error, timeout_seconds=5, preexec_fn=None
        )
        summary = CAPTURE.summarize_raw(raw, requested_sample_count=2)

        self.assertEqual(status, 0)
        self.assertEqual(summary.nul_delimiter_count, 2)
        self.assertEqual(summary.byte_count, len(b"plist-one\0plist-two\0"))
        self.assertEqual(CAPTURE.bounded_stderr_size(error), 0)

    def test_rejects_empty_unseparated_and_excessively_delimited_raw(self) -> None:
        raw = self.root / "raw.partial"
        raw.write_bytes(b"")
        with self.assertRaises(CAPTURE.CaptureError):
            CAPTURE.summarize_raw(raw, requested_sample_count=2)
        raw.write_bytes(b"one-plist")
        with self.assertRaises(CAPTURE.CaptureError):
            CAPTURE.summarize_raw(raw, requested_sample_count=2)
        raw.write_bytes(b"x\0" * 35)
        with self.assertRaises(CAPTURE.CaptureError):
            CAPTURE.summarize_raw(raw, requested_sample_count=2)

    def test_metadata_remains_raw_only_and_item_nine_open(self) -> None:
        request = self.request()
        identity = CAPTURE.ExecutableIdentity(
            process_name="FarPane",
            sha256="a" * 64,
            device=1,
            inode=2,
            size=3,
            modified_nanoseconds=4,
        )
        raw_path, _ = CAPTURE.output_paths(request.output_prefix)
        metadata = CAPTURE.build_metadata(
            request,
            identity,
            raw_path,
            CAPTURE.RawSummary("b" * 64, 100, 2),
            "2026-08-10T00:00:00Z",
            "2026-08-10T00:00:02Z",
            2.0,
            0,
            {
                "machineModel": "MacBookPro18,3",
                "architecture": "arm64",
                "macOSVersion": "15.6",
            },
        )

        self.assertEqual(metadata["schemaVersion"], 1)
        self.assertFalse(metadata["authority"]["wrapperInvokesSudo"])
        self.assertFalse(metadata["claims"]["rawSourceParsed"])
        self.assertFalse(metadata["claims"]["batterySourceThroughoutProven"])
        self.assertFalse(metadata["claims"]["section15_2Item9Complete"])
        self.assertNotIn("device", metadata["host"])
        self.assertNotIn("inode", metadata["host"])

    def test_publishes_raw_and_metadata_without_replacement(self) -> None:
        raw_temporary = self.root / ".raw.partial"
        raw_temporary.write_bytes(b"plist-one\0plist-two\0")
        raw_path, metadata_path = CAPTURE.output_paths(self.prefix)
        metadata = {"schema": CAPTURE.SCHEMA, "schemaVersion": 1}

        CAPTURE.publish_pair_no_replace(
            raw_temporary, raw_path, metadata, metadata_path
        )

        self.assertEqual(raw_path.read_bytes(), raw_temporary.read_bytes())
        self.assertEqual(json.loads(metadata_path.read_text()), metadata)
        self.assertEqual(raw_path.stat().st_mode & 0o777, 0o644)
        with self.assertRaises(CAPTURE.CaptureError):
            CAPTURE.publish_pair_no_replace(
                raw_temporary, raw_path, metadata, metadata_path
            )


if __name__ == "__main__":
    unittest.main()
