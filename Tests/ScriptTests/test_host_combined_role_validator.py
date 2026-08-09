from datetime import datetime, timedelta, timezone
import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "Scripts/validate-farpane-host-combined-role.py"
SPEC = importlib.util.spec_from_file_location(
    "validate_farpane_host_combined_role", SCRIPT_PATH
)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VALIDATOR
SPEC.loader.exec_module(VALIDATOR)


class HostCombinedRoleValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(dir=REPO_ROOT)
        self.root = Path(self.temporary_directory.name)
        self.manifest_path = self.root / "manifest.json"
        self.output_path = self.root / "result.json"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    @staticmethod
    def digest(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    @staticmethod
    def utc(value: datetime) -> str:
        return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")

    def make_fixture(
        self,
        *,
        scenario: str = "host-ready-viewer",
        duration: int = 2,
        sample_mode: str = "smoke",
    ) -> None:
        base = datetime(2026, 8, 10, tzinfo=timezone.utc)
        start_mono = 100_000_000_000
        end_mono = start_mono + duration * 1_000_000_000
        host_pid = 101
        viewer_pid = 202
        build = "202608100001"
        dual = scenario == "host-viewer-dual"

        samples_path = self.root / "system.samples.csv"
        with samples_path.open("w", newline="", encoding="utf-8") as output:
            writer = csv.DictWriter(output, fieldnames=VALIDATOR.CSV_HEADER)
            writer.writeheader()
            for index in range(duration):
                monotonic = start_mono + int((index + 0.5) * 1_000_000_000)
                host_cpu = 10.0 if dual else 1.0
                viewer_cpu = 10.0
                row = {
                    "elapsed_seconds": f"{index + 0.5:.3f}",
                    "monotonic_nanoseconds": str(monotonic),
                    "scenario": scenario,
                    "host_agent_pid": str(host_pid),
                    "host_agent_cpu_percent": f"{host_cpu:.3f}",
                    "host_agent_rss_kb": "10000",
                    "host_agent_threads": "10",
                    "host_agent_energy_impact": "0.500",
                    "viewer_pid": str(viewer_pid),
                    "viewer_cpu_percent": f"{viewer_cpu:.3f}",
                    "viewer_rss_kb": "20000",
                    "viewer_threads": "20",
                    "viewer_energy_impact": "1.000",
                    "farpane_combined_cpu_percent": f"{host_cpu + viewer_cpu:.3f}",
                    "farpane_combined_rss_kb": "30000",
                    "farpane_combined_threads": "30",
                    "farpane_combined_energy_impact": "1.500",
                    "windowserver_cpu_percent": "5.000",
                    "windowserver_rss_kb": "50000",
                    "windowserver_threads": "50",
                    "windowserver_energy_impact": "2.000",
                    "videotoolboxd_cpu_percent": "2.000",
                    "videotoolboxd_rss_kb": "10000",
                    "videotoolboxd_threads": "5",
                    "videotoolboxd_energy_impact": "0.500",
                    "vt_encoder_xpc_cpu_percent": "1.000",
                    "vt_encoder_xpc_rss_kb": "5000",
                    "vt_encoder_xpc_threads": "3",
                    "vt_encoder_xpc_energy_impact": "0.250",
                    "system_cpu_user_percent": "10.000",
                    "system_cpu_sys_percent": "10.000",
                    "system_cpu_idle_percent": "80.000",
                    "memory_free_percent": "50.000",
                    "thermal_pressure": "nominal",
                    "power_source": "ac",
                    "host_agent_sleep_assertion_count": "1" if dual else "0",
                    "host_agent_user_idle_sleep_assertion_count": "1" if dual else "0",
                    "host_agent_display_sleep_assertion_count": "0",
                    "viewer_sleep_assertion_count": "0",
                    "viewer_user_idle_sleep_assertion_count": "0",
                    "viewer_display_sleep_assertion_count": "0",
                }
                writer.writerow(row)

        log_path = self.root / "system.log"
        log_path.write_text("completed=true\n", encoding="utf-8")
        executable_sha = "a" * 64
        role_base = {
            "processName": "RustDeskNative",
            "executableSHA256": executable_sha,
            "bundleIdentifier": "io.rustdesknative.viewer",
            "buildIdentifier": build,
            "shortVersion": "0.1.0",
            "startMarker": "Mon Aug 10 00:00:00 2026",
        }
        system = {
            "schema": VALIDATOR.SYSTEM_SCHEMA,
            "schemaVersion": 1,
            "scenario": scenario,
            "sampleMode": sample_mode,
            "requestedDurationSeconds": duration,
            "sampleCadenceTargetMilliseconds": 1_000,
            "sampleCount": duration,
            "completed": True,
            "window": {
                "startedAt": self.utc(base),
                "completedAt": self.utc(base + timedelta(seconds=duration)),
                "startedMonotonicNanoseconds": start_mono,
                "completedMonotonicNanoseconds": end_mono,
                "monotonicDurationSeconds": float(duration),
            },
            "machine": {
                "machineModel": "Macmini10,1",
                "architecture": "arm64",
                "macOSVersion": "15.6",
            },
            "roles": {
                "hostAgent": {
                    **role_base,
                    "pid": host_pid,
                    "role": "host-agent",
                    "argumentsSHA256": "b" * 64,
                    "hostAgentFlagCount": 1,
                },
                "viewer": {
                    **role_base,
                    "pid": viewer_pid,
                    "role": "viewer",
                    "argumentsSHA256": "c" * 64,
                    "hostAgentFlagCount": 0,
                },
                "distinctPIDs": True,
                "sameExecutablePath": True,
                "sameExecutableSHA256": True,
                "sameBuildIdentifier": True,
            },
            "resourceAuthority": {
                "roleProcessScope": "exact-pid-per-second",
                "combinedProcessScope": "host-agent-plus-viewer-only",
                "sharedSystemScope": [
                    "WindowServer",
                    "videotoolboxd",
                    "VTEncoderXPCService",
                ],
                "sharedSystemScopeAssignedToRole": False,
                "energyImpactAvailable": True,
                "energyImpactUnit": "top-relative-not-joules",
            },
            "artifacts": {
                "samples": {
                    "path": samples_path.name,
                    "sha256": self.digest(samples_path),
                },
                "log": {"path": log_path.name, "sha256": self.digest(log_path)},
            },
            "claims": {
                "hostRuntimeStateBound": False,
                "viewerStreamingReportBound": False,
                "combinedBudgetThresholdEvaluated": False,
                "section15_2Item10Complete": False,
            },
        }
        system_path = self.root / "system.json"
        system_path.write_text(json.dumps(system, sort_keys=True) + "\n", encoding="utf-8")

        state_path = self.root / "host-state.jsonl"
        with state_path.open("w", encoding="utf-8") as output:
            for sequence, offset in enumerate(range(-1, duration + 2), start=1):
                captured = base + timedelta(seconds=offset)
                record = {
                    "schema": VALIDATOR.HOST_STATE_SCHEMA,
                    "schemaVersion": 2,
                    "sequence": sequence,
                    "capturedAt": self.utc(captured),
                    "monotonicNanoseconds": start_mono + offset * 1_000_000_000,
                    "hostRuntimeActive": True,
                    "hostState": "ready",
                    "registrationStatus": "ready",
                    "hostSnapshotObservedAtUnixMilliseconds": int(
                        captured.timestamp() * 1_000
                    )
                    - 100,
                    "authenticatedConnectionCount": 1 if dual else 0,
                    "mediaRouteActive": dual,
                    "mediaPipelineActive": dual,
                }
                if offset == -1:
                    record.update({
                        "hostRuntimeActive": False,
                        "hostState": "unavailable",
                        "registrationStatus": "unavailable",
                        "hostSnapshotObservedAtUnixMilliseconds": None,
                        "authenticatedConnectionCount": None,
                        "mediaRouteActive": False,
                        "mediaPipelineActive": False,
                    })
                output.write(json.dumps(record, sort_keys=True) + "\n")

        viewer_path = self.root / "viewer.json"
        viewer = {
            "schema": VALIDATOR.VIEWER_SCHEMA,
            "schemaVersion": 1,
            "processID": viewer_pid,
            "bundleIdentifier": "io.rustdesknative.viewer",
            "buildIdentifier": build,
            "measurementStartedAt": self.utc(base - timedelta(seconds=1)),
            "measurementStartedMonotonicNanoseconds": start_mono - 1_000_000_000,
            "measurementCompletedMonotonicNanoseconds": end_mono + 1_000_000_000,
            "firstPresentationMonotonicNanoseconds": start_mono - 500_000_000,
            "lastPresentationMonotonicNanoseconds": end_mono + 500_000_000,
            "timestamp": self.utc(base + timedelta(seconds=duration + 1)),
            "source": "rustdesk-live",
            "durationSeconds": float(duration + 2),
            "processCPUPercent": 10.0,
            "initialResidentMB": 20.0,
            "finalResidentMB": 30.0,
            "peakResidentMB": 35.0,
            "decodedFrames": max(1, duration * 20),
            "presentedFrames": max(1, duration * 19),
            "encodedFrames": max(1, duration * 20),
            "hardwareDecodeActive": True,
            "coreStateTransitions": [
                "connecting:0:connecting",
                "authenticated:0:authenticated",
                "streaming:0:streaming",
            ],
            "maxPresentationGapMS": 1_000.0,
            "finalPresentationStalenessMS": 500.0,
        }
        viewer_path.write_text(json.dumps(viewer, sort_keys=True) + "\n", encoding="utf-8")

        sources = {
            "systemMetadata": system_path,
            "systemSamples": samples_path,
            "systemLog": log_path,
            "hostRuntimeState": state_path,
            "viewerReport": viewer_path,
        }
        manifest = {
            "schema": VALIDATOR.MANIFEST_SCHEMA,
            "schemaVersion": 1,
            "scenario": scenario,
            "sources": {
                name: {"path": path.name, "sha256": self.digest(path)}
                for name, path in sources.items()
            },
        }
        self.manifest_path.write_text(
            json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8"
        )

    def refresh_hashes(self) -> None:
        system_path = self.root / "system.json"
        system = json.loads(system_path.read_text())
        samples_path = self.root / "system.samples.csv"
        log_path = self.root / "system.log"
        system["artifacts"]["samples"]["sha256"] = self.digest(samples_path)
        system["artifacts"]["log"]["sha256"] = self.digest(log_path)
        system_path.write_text(json.dumps(system, sort_keys=True) + "\n")
        manifest = json.loads(self.manifest_path.read_text())
        for source in manifest["sources"].values():
            source["sha256"] = self.digest(self.root / source["path"])
        self.manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n")

    def test_accepts_complete_ready_viewer_acceptance(self) -> None:
        self.make_fixture(duration=600, sample_mode="acceptance")

        result = VALIDATOR.validate(self.manifest_path)

        self.assertEqual(result["status"], "pass", result["failures"])
        self.assertEqual(result["failures"], [])
        self.assertTrue(result["claims"]["scenarioEvidenceComplete"])
        self.assertFalse(result["claims"]["section15_2Item10Complete"])
        self.assertEqual(result["scope"]["machineModel"], "Macmini10,1")
        self.assertEqual(result["scope"]["architecture"], "arm64")
        self.assertEqual(result["scope"]["buildIdentifier"], "202608100001")
        self.assertEqual(result["scope"]["executableSHA256"], "a" * 64)
        self.assertEqual(result["metrics"]["system"]["sampleCount"], 600)
        self.assertLess(
            result["metrics"]["system"]["combinedAverageCPUPercent"], 62
        )

    def test_accepts_dual_active_smoke_but_does_not_complete_scenario(self) -> None:
        self.make_fixture(scenario="host-viewer-dual")

        result = VALIDATOR.validate(self.manifest_path)

        self.assertEqual(result["status"], "pass", result["failures"])
        self.assertFalse(result["claims"]["scenarioEvidenceComplete"])
        self.assertEqual(
            result["thresholds"]["combinedAverageCPUCeilingPercent"], 85.0
        )

    def test_rejects_viewer_pid_and_continuity_mismatch(self) -> None:
        self.make_fixture()
        viewer_path = self.root / "viewer.json"
        viewer = json.loads(viewer_path.read_text())
        viewer["processID"] = 303
        viewer["maxPresentationGapMS"] = 3_000
        viewer_path.write_text(json.dumps(viewer, sort_keys=True) + "\n")
        self.refresh_hashes()

        result = VALIDATOR.validate(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        self.assertIn(
            "Viewer report PID does not match system evidence", result["failures"]
        )
        self.assertIn(
            "Viewer presentation gap exceeds 2.5 seconds", result["failures"]
        )

    def test_rejects_host_state_that_changes_inside_window(self) -> None:
        self.make_fixture()
        state_path = self.root / "host-state.jsonl"
        records = [json.loads(line) for line in state_path.read_text().splitlines()]
        records[2]["authenticatedConnectionCount"] = 1
        state_path.write_text(
            "".join(json.dumps(record, sort_keys=True) + "\n" for record in records)
        )
        self.refresh_hashes()

        result = VALIDATOR.validate(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        self.assertTrue(
            any("has an inbound connection" in value for value in result["failures"])
        )

    def test_rejects_combined_resource_mismatch_and_threshold(self) -> None:
        self.make_fixture()
        samples_path = self.root / "system.samples.csv"
        with samples_path.open(newline="", encoding="utf-8") as source:
            rows = list(csv.DictReader(source))
        rows[0]["host_agent_cpu_percent"] = "70.000"
        with samples_path.open("w", newline="", encoding="utf-8") as output:
            writer = csv.DictWriter(output, fieldnames=VALIDATOR.CSV_HEADER)
            writer.writeheader()
            writer.writerows(rows)
        self.refresh_hashes()

        result = VALIDATOR.validate(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        self.assertTrue(
            any("row 1" in value for value in result["failures"]),
            result["failures"],
        )

    def test_rejects_source_hash_and_path_escape_before_semantics(self) -> None:
        self.make_fixture()
        manifest = json.loads(self.manifest_path.read_text())
        manifest["sources"]["viewerReport"]["sha256"] = "f" * 64
        self.manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n")
        with self.assertRaisesRegex(VALIDATOR.ValidationError, "SHA-256"):
            VALIDATOR.validate(self.manifest_path)

        manifest["sources"]["viewerReport"] = {
            "path": "../viewer.json",
            "sha256": "f" * 64,
        }
        self.manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n")
        with self.assertRaisesRegex(VALIDATOR.ValidationError, "unsafe"):
            VALIDATOR.validate(self.manifest_path)

    def test_rejects_symlink_and_duplicate_source_identity(self) -> None:
        self.make_fixture()
        viewer = self.root / "viewer.json"
        linked = self.root / "linked-viewer.json"
        linked.symlink_to(viewer.name)
        manifest = json.loads(self.manifest_path.read_text())
        manifest["sources"]["viewerReport"] = {
            "path": linked.name,
            "sha256": self.digest(viewer),
        }
        self.manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n")
        with self.assertRaisesRegex(VALIDATOR.ValidationError, "symlink"):
            VALIDATOR.validate(self.manifest_path)

        linked.unlink()
        duplicate = self.root / "duplicate.json"
        duplicate.hardlink_to(viewer)
        manifest["sources"]["viewerReport"] = {
            "path": duplicate.name,
            "sha256": self.digest(viewer),
        }
        self.manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n")
        with self.assertRaisesRegex(VALIDATOR.ValidationError, "identity or size"):
            VALIDATOR.validate(self.manifest_path)

    def test_cli_publishes_once_and_refuses_overwrite(self) -> None:
        self.make_fixture()
        command = [
            sys.executable,
            str(SCRIPT_PATH),
            str(self.manifest_path),
            str(self.output_path),
        ]

        first = subprocess.run(command, check=False, capture_output=True, text=True)
        second = subprocess.run(command, check=False, capture_output=True, text=True)

        self.assertEqual(first.returncode, 0, first.stderr or first.stdout)
        self.assertIn("status=pass", first.stdout)
        self.assertEqual(json.loads(self.output_path.read_text())["status"], "pass")
        self.assertEqual(second.returncode, 2)
        self.assertIn("refusing to overwrite", second.stderr)


if __name__ == "__main__":
    unittest.main()
