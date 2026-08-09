import csv
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "Scripts/sample-farpane-host-combined-role.py"
SPEC = importlib.util.spec_from_file_location(
    "sample_farpane_host_combined_role", SCRIPT_PATH
)
assert SPEC is not None and SPEC.loader is not None
SAMPLER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SAMPLER
SPEC.loader.exec_module(SAMPLER)


class HostCombinedRoleSamplerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(dir=REPO_ROOT)
        self.root = Path(self.temporary_directory.name)
        self.prefix = self.root / "combined-run"
        self.executable = (
            self.root / "FarPane.app/Contents/MacOS/RustDeskNative"
        )
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b"same-farpane-build")
        info = {
            "CFBundleIdentifier": "io.rustdesknative.viewer",
            "CFBundleExecutable": "RustDeskNative",
            "CFBundleVersion": "202608100001",
            "CFBundleShortVersionString": "0.1.0",
        }
        with (self.executable.parent.parent / "Info.plist").open("wb") as output:
            plistlib.dump(info, output)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def request(self, duration: str = "2", mode: str = "smoke"):
        return SAMPLER.validate_request(
            "host-ready-viewer",
            duration,
            str(self.prefix),
            "101",
            "202",
            mode,
        )

    def process_identity(
        self,
        pid: int,
        role: str,
        flag_count: int,
        *,
        executable: Path | None = None,
        build_identifier: str = "202608100001",
    ):
        executable_path = executable or self.executable
        executable_identity = SAMPLER.hash_open_executable(executable_path)
        bundle = SAMPLER.BundleIdentity(
            bundle_identifier="io.rustdesknative.viewer",
            build_identifier=build_identifier,
            short_version="0.1.0",
        )
        return SAMPLER.ProcessIdentity(
            pid=pid,
            role=role,
            executable=executable_identity,
            bundle=bundle,
            start_marker=f"Mon Aug 10 00:00:0{pid % 10} 2026",
            arguments_sha256=hashlib.sha256(f"argv-{pid}".encode()).hexdigest(),
            host_agent_flag_count=flag_count,
        )

    def test_acceptance_and_smoke_request_boundaries(self) -> None:
        acceptance = SAMPLER.validate_request(
            "host-viewer-dual",
            "600",
            str(self.prefix),
            "101",
            "202",
            "acceptance",
        )
        smoke = self.request()

        self.assertEqual(acceptance.duration_seconds, 600)
        self.assertEqual(smoke.duration_seconds, 2)
        for duration, mode in (("599", "acceptance"), ("1801", "acceptance"), ("61", "smoke")):
            with self.assertRaises(SAMPLER.SampleError):
                SAMPLER.validate_request(
                    "host-ready-viewer",
                    duration,
                    str(self.prefix),
                    "101",
                    "202",
                    mode,
                )

    def test_rejects_unknown_scenario_same_pid_and_unsafe_output(self) -> None:
        with self.assertRaises(SAMPLER.SampleError):
            SAMPLER.validate_request(
                "viewer-only", "600", str(self.prefix), "101", "202", "acceptance"
            )
        with self.assertRaisesRegex(SAMPLER.SampleError, "distinct"):
            SAMPLER.validate_request(
                "host-ready-viewer",
                "600",
                str(self.prefix),
                "101",
                "101",
                "acceptance",
            )
        with self.assertRaisesRegex(SAMPLER.SampleError, "absolute"):
            SAMPLER.validate_request(
                "host-ready-viewer", "600", "relative/run", "101", "202", "acceptance"
            )
        linked = self.root / "linked"
        linked.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(SAMPLER.SampleError, "symlink"):
            SAMPLER.validate_request(
                "host-ready-viewer",
                "600",
                str(linked / "run"),
                "101",
                "202",
                "acceptance",
            )

    def test_parses_bounded_kern_procargs_without_environment(self) -> None:
        raw = (
            struct.pack("=i", 2)
            + b"/Applications/FarPane.app/Contents/MacOS/RustDeskNative\0\0"
            + b"RustDeskNative\0--host-agent\0SECRET=not-an-argument\0"
        )

        arguments = SAMPLER.parse_kern_procargs2(raw)

        self.assertEqual(arguments, ("RustDeskNative", "--host-agent"))
        self.assertEqual(
            SAMPLER.hash_arguments(arguments),
            hashlib.sha256(b"RustDeskNative\0--host-agent\0").hexdigest(),
        )
        with self.assertRaises(SAMPLER.SampleError):
            SAMPLER.parse_kern_procargs2(struct.pack("=i", 2) + b"/path\0\0one\0")

    def test_captures_exact_role_without_persisting_arguments(self) -> None:
        host_runtime = SAMPLER.RuntimeProcessSnapshot(
            pid=101,
            executable_path=self.executable,
            start_marker="Mon Aug 10 00:00:01 2026",
            arguments_sha256="a" * 64,
            host_agent_flag_count=1,
        )
        viewer_runtime = SAMPLER.RuntimeProcessSnapshot(
            pid=202,
            executable_path=self.executable,
            start_marker="Mon Aug 10 00:00:02 2026",
            arguments_sha256="b" * 64,
            host_agent_flag_count=0,
        )
        host = SAMPLER.capture_process_identity(
            101, "host-agent", runtime_observer=lambda _pid: host_runtime
        )
        viewer = SAMPLER.capture_process_identity(
            202, "viewer", runtime_observer=lambda _pid: viewer_runtime
        )

        SAMPLER.validate_role_pair(host, viewer)
        self.assertEqual(host.bundle.build_identifier, "202608100001")
        self.assertEqual(host.executable.sha256, viewer.executable.sha256)
        self.assertEqual(host.host_agent_flag_count, 1)
        self.assertEqual(viewer.host_agent_flag_count, 0)

        wrong_viewer = SAMPLER.RuntimeProcessSnapshot(
            **{**viewer_runtime.__dict__, "host_agent_flag_count": 1}
        )
        with self.assertRaisesRegex(SAMPLER.SampleError, "exact viewer"):
            SAMPLER.capture_process_identity(
                202, "viewer", runtime_observer=lambda _pid: wrong_viewer
            )

    def test_role_pair_rejects_path_build_or_pid_alias(self) -> None:
        host = self.process_identity(101, "host-agent", 1)
        viewer = self.process_identity(202, "viewer", 0)
        SAMPLER.validate_role_pair(host, viewer)

        copied = self.root / "Other.app/Contents/MacOS/RustDeskNative"
        copied.parent.mkdir(parents=True)
        copied.write_bytes(self.executable.read_bytes())
        different_path = self.process_identity(202, "viewer", 0, executable=copied)
        with self.assertRaisesRegex(SAMPLER.SampleError, "same executable path"):
            SAMPLER.validate_role_pair(host, different_path)
        different_build = self.process_identity(
            202, "viewer", 0, build_identifier="202608100002"
        )
        with self.assertRaisesRegex(SAMPLER.SampleError, "build identity"):
            SAMPLER.validate_role_pair(host, different_build)
        aliased_pid = SAMPLER.ProcessIdentity(**{**viewer.__dict__, "pid": 101})
        with self.assertRaisesRegex(SAMPLER.SampleError, "distinct"):
            SAMPLER.validate_role_pair(host, aliased_pid)

    def test_runtime_snapshot_detects_pid_reuse_or_argument_change(self) -> None:
        host = self.process_identity(101, "host-agent", 1)
        matching = SAMPLER.RuntimeProcessSnapshot(
            pid=host.pid,
            executable_path=host.executable.path,
            start_marker=host.start_marker,
            arguments_sha256=host.arguments_sha256,
            host_agent_flag_count=host.host_agent_flag_count,
        )
        SAMPLER.require_runtime_matches(host, matching)
        changed = SAMPLER.RuntimeProcessSnapshot(
            **{**matching.__dict__, "start_marker": "Mon Aug 10 00:01:01 2026"}
        )
        with self.assertRaisesRegex(SAMPLER.SampleError, "changed"):
            SAMPLER.require_runtime_matches(host, changed)

    def test_parses_process_top_assertion_and_system_evidence(self) -> None:
        stats = SAMPLER.parse_process_stats(
            "12.5 4096",
            "USER PID TT %CPU\nuser 101 ?? 6.2\nuser 101 ?? 6.3\n",
        )
        energies, system_cpu = SAMPLER.parse_top_snapshot(
            "CPU usage: 10.0% user, 20.0% sys, 70.0% idle\n"
            "PID POWER\n101 1.5\n202 2.0\n"
        )
        assertions = SAMPLER.read_assertion_counts(
            "pid 101(FarPane): PreventUserIdleSystemSleep\n"
            "pid 202(FarPane): PreventUserIdleDisplaySleep\n",
            101,
        )

        self.assertEqual(stats, SAMPLER.ProcessStats(12.5, 4096, 2))
        self.assertEqual(system_cpu, (10.0, 20.0, 70.0))
        self.assertEqual(SAMPLER.energy_value(energies, (101, 202)), 3.5)
        self.assertIsNone(SAMPLER.energy_value(energies, (101, 303)))
        self.assertEqual(assertions.total, 1)
        self.assertEqual(assertions.user_idle_system_sleep, 1)
        self.assertEqual(assertions.user_idle_display_sleep, 0)
        self.assertEqual(
            SAMPLER.parse_memory_free("System-wide memory free percentage: 73%"),
            73.0,
        )
        self.assertEqual(
            SAMPLER.parse_thermal("Thermal_Pressure_Level: Nominal"), "nominal"
        )
        self.assertEqual(
            SAMPLER.parse_power_source("Now drawing from 'Battery Power'"),
            "battery",
        )

    def test_metadata_keeps_roles_split_and_item_ten_open(self) -> None:
        request = self.request()
        host = self.process_identity(101, "host-agent", 1)
        viewer = self.process_identity(202, "viewer", 0)
        metadata = SAMPLER.build_metadata(
            request,
            host,
            viewer,
            {
                "machineModel": "Macmini10,1",
                "architecture": "arm64",
                "macOSVersion": "15.6",
            },
            "2026-08-10T00:00:00Z",
            "2026-08-10T00:00:02Z",
            1_000_000_000,
            3_000_000_000,
            2,
            self.prefix.with_name(self.prefix.name + ".samples.csv"),
            "c" * 64,
            self.prefix.with_name(self.prefix.name + ".log"),
            "d" * 64,
            True,
        )

        self.assertEqual(metadata["schemaVersion"], 1)
        self.assertEqual(
            metadata["resourceAuthority"]["roleProcessScope"],
            "exact-pid-per-second",
        )
        self.assertFalse(
            metadata["resourceAuthority"]["sharedSystemScopeAssignedToRole"]
        )
        self.assertTrue(metadata["roles"]["distinctPIDs"])
        self.assertTrue(metadata["roles"]["sameExecutableSHA256"])
        self.assertFalse(metadata["claims"]["hostRuntimeStateBound"])
        self.assertFalse(metadata["claims"]["viewerStreamingReportBound"])
        self.assertFalse(metadata["claims"]["section15_2Item10Complete"])
        serialized = json.dumps(metadata)
        self.assertNotIn("--host-agent", serialized)
        self.assertNotIn(str(self.executable), serialized)

    def test_publishes_complete_triplet_without_replacement(self) -> None:
        csv_temporary = self.root / ".samples.tmp"
        log_temporary = self.root / ".log.tmp"
        with csv_temporary.open("w", newline="", encoding="utf-8") as output:
            writer = csv.writer(output)
            writer.writerow(SAMPLER.CSV_HEADER)
        log_temporary.write_text("complete\n", encoding="utf-8")
        csv_path, metadata_path, log_path = SAMPLER.output_paths(self.prefix)
        metadata = {"schema": SAMPLER.SCHEMA, "schemaVersion": 1}

        SAMPLER.publish_triplet_no_replace(
            csv_temporary,
            csv_path,
            metadata,
            metadata_path,
            log_temporary,
            log_path,
        )

        self.assertTrue(csv_path.is_file())
        self.assertEqual(json.loads(metadata_path.read_text()), metadata)
        self.assertEqual(log_path.read_text(), "complete\n")
        with self.assertRaises(SAMPLER.SampleError):
            SAMPLER.publish_triplet_no_replace(
                csv_temporary,
                csv_path,
                metadata,
                metadata_path,
                log_temporary,
                log_path,
            )


if __name__ == "__main__":
    unittest.main()
