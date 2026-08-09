import csv
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
VALIDATOR_PATH = REPO_ROOT / "Scripts" / "validate-farpane-host-idle.py"
SPEC = importlib.util.spec_from_file_location("validate_farpane_host_idle", VALIDATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class HostIdleValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.duration = 3
        self.start_ms = 1_700_000_000_000
        self.end_ms = self.start_ms + self.duration * 1_000
        self.state_path = self.root / "state.jsonl"
        self.system_path = self.root / "system.json"
        self.samples_path = self.root / "samples.csv"
        self._write_state()
        self._write_system()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _captured_at(self, unix_ms: int) -> str:
        return datetime.fromtimestamp(
            unix_ms / 1_000, timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ")

    def _state_record(self, sequence: int, unix_ms: int) -> dict:
        return {
            "schema": "farpane-host-runtime-state",
            "schemaVersion": 2,
            "sequence": sequence,
            "capturedAt": self._captured_at(unix_ms),
            "monotonicNanoseconds": sequence * 1_000_000_000,
            "hostRuntimeActive": True,
            "hostState": "ready",
            "registrationStatus": "ready",
            "hostSnapshotObservedAtUnixMilliseconds": unix_ms,
            "authenticatedConnectionCount": 0,
            "mediaRouteActive": False,
            "mediaPipelineActive": False,
        }

    def _write_state(self, records: list[dict] | None = None) -> None:
        if records is None:
            records = [
                self._state_record(index + 10, self.start_ms + index * 1_000)
                for index in range(self.duration + 1)
            ]
        self.state_path.write_text(
            "".join(json.dumps(record) + "\n" for record in records),
            encoding="utf-8",
        )

    def _write_system(
        self,
        *,
        host_cpu: float = 1.5,
        assertion_count: int = 0,
        sample_mode: str = "smoke",
        completed: bool = True,
        sampler_exit_status: int = 0,
    ) -> None:
        self.system_path.write_text(
            json.dumps(
                {
                    "schemaVersion": 3,
                    "sampler": "farpane-host-system",
                    "scenario": "host-ready-no-screen-route",
                    "sampleMode": sample_mode,
                    "requestedDurationSeconds": self.duration,
                    "actualDurationSeconds": float(self.duration),
                    "sampleCount": self.duration,
                    "completed": completed,
                    "samplerExitStatus": sampler_exit_status,
                    "machineModel": "MacBookPro11,3",
                    "architecture": "x86_64",
                    "macOSVersion": "12.7.6",
                }
            ),
            encoding="utf-8",
        )
        fieldnames = [
            "elapsed_seconds",
            "scenario",
            "host_cpu_percent",
            "host_rss_kb",
            "host_threads",
            "windowserver_cpu_percent",
            "videotoolboxd_cpu_percent",
            "vt_encoder_xpc_cpu_percent",
            "host_sleep_assertion_count",
            "host_user_idle_sleep_assertion_count",
            "host_display_sleep_assertion_count",
        ]
        with self.samples_path.open("w", newline="", encoding="utf-8") as output:
            writer = csv.DictWriter(output, fieldnames=fieldnames)
            writer.writeheader()
            for index in range(self.duration):
                writer.writerow(
                    {
                        "elapsed_seconds": index,
                        "scenario": "host-ready-no-screen-route",
                        "host_cpu_percent": host_cpu,
                        "host_rss_kb": 100_000,
                        "host_threads": 12,
                        "windowserver_cpu_percent": 3.0,
                        "videotoolboxd_cpu_percent": 0.1,
                        "vt_encoder_xpc_cpu_percent": 0.0,
                        "host_sleep_assertion_count": assertion_count,
                        "host_user_idle_sleep_assertion_count": assertion_count,
                        "host_display_sleep_assertion_count": 0,
                    }
                )

    def _validate(self) -> dict:
        return VALIDATOR.validate_idle_run(
            duration=self.duration,
            state_path=self.state_path,
            system_path=self.system_path,
            samples_path=self.samples_path,
            window_start_unix_ms=self.start_ms,
            window_end_unix_ms=self.end_ms,
        )

    def test_accepts_ready_no_screen_route_smoke_fixture(self) -> None:
        result = self._validate()

        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["failures"], [])
        self.assertEqual(result["machineModel"], "MacBookPro11,3")
        self.assertEqual(result["architecture"], "x86_64")
        self.assertEqual(result["macOSVersion"], "12.7.6")
        self.assertTrue(result["hostReadyThroughout"])
        self.assertTrue(result["registrationReadyThroughout"])
        self.assertTrue(result["screenMediaRouteAbsentThroughout"])
        self.assertTrue(result["allAuthenticatedConnectionsProvenAbsent"])
        self.assertEqual(
            result["authenticatedConnectionCoverage"],
            "all-rustdesk-authenticated-types",
        )

    def test_rejects_route_pipeline_or_non_ready_transition(self) -> None:
        mutations = {
            "route": ("mediaRouteActive", True),
            "pipeline": ("mediaPipelineActive", True),
            "host": ("hostState", "starting"),
            "registration": ("registrationStatus", "pending"),
        }
        for label, (field, value) in mutations.items():
            with self.subTest(label=label):
                records = [
                    self._state_record(index + 10, self.start_ms + index * 1_000)
                    for index in range(self.duration + 1)
                ]
                records[1][field] = value
                self._write_state(records)
                self.assertEqual(self._validate()["status"], "fail")

    def test_rejects_cpu_boundary_and_any_host_assertion(self) -> None:
        self._write_system(host_cpu=2.0)
        cpu_result = self._validate()
        self.assertEqual(cpu_result["status"], "fail")
        self.assertIn(
            "Host average CPU did not remain below 2 percent",
            cpu_result["failures"],
        )

        self._write_system(host_cpu=1.0, assertion_count=1)
        assertion_result = self._validate()
        self.assertEqual(assertion_result["status"], "fail")
        self.assertIn(
            "Host held a sleep assertion during the no-screen-route window",
            assertion_result["failures"],
        )

    def test_rejects_any_authenticated_or_unknown_connection_count(self) -> None:
        records = [
            self._state_record(index + 10, self.start_ms + index * 1_000)
            for index in range(self.duration + 1)
        ]
        records[1]["authenticatedConnectionCount"] = 1
        self._write_state(records)

        connected = self._validate()

        self.assertEqual(connected["status"], "fail")
        self.assertFalse(connected["allAuthenticatedConnectionsProvenAbsent"])
        self.assertIn(
            "an authenticated connection existed during the idle window",
            connected["failures"],
        )

        records[1]["authenticatedConnectionCount"] = None
        self._write_state(records)
        unknown = self._validate()
        self.assertEqual(unknown["status"], "fail")
        self.assertFalse(unknown["allAuthenticatedConnectionsProvenAbsent"])
        self.assertIn(
            "authenticated connection count was unavailable during the idle window",
            unknown["failures"],
        )

    def test_rejects_state_gap_sequence_gap_and_stale_snapshot(self) -> None:
        records = [
            self._state_record(10, self.start_ms),
            self._state_record(12, self.end_ms),
        ]
        records[-1]["hostSnapshotObservedAtUnixMilliseconds"] = self.end_ms - 10_000
        self._write_state(records)

        result = self._validate()

        self.assertEqual(result["status"], "fail")
        self.assertIn("runtime-state sequence is not contiguous", result["failures"])
        self.assertIn(
            "runtime-state evidence contains a gap longer than 2.5 seconds",
            result["failures"],
        )
        self.assertIn(
            "Host snapshot timestamps were stale or implausibly in the future",
            result["failures"],
        )

    def test_rejects_short_acceptance_and_incomplete_sampler(self) -> None:
        self._write_system(
            sample_mode="acceptance", completed=False, sampler_exit_status=1
        )

        result = self._validate()

        self.assertEqual(result["status"], "fail")
        self.assertIn(
            "idle acceptance evidence is shorter than 600 seconds",
            result["failures"],
        )
        self.assertIn(
            "system sampler did not complete the requested window",
            result["failures"],
        )
        self.assertIn(
            "system sampler recorded a nonzero exit status", result["failures"]
        )

    def test_rejects_missing_or_unsupported_machine_identity(self) -> None:
        system = json.loads(self.system_path.read_text(encoding="utf-8"))
        system["machineModel"] = " MacBookPro11,3"
        system["architecture"] = "i386"
        del system["macOSVersion"]
        self.system_path.write_text(json.dumps(system), encoding="utf-8")

        result = self._validate()

        self.assertEqual(result["status"], "fail")
        self.assertIn(
            "system evidence machine model is missing or invalid",
            result["failures"],
        )
        self.assertIn(
            "system evidence architecture must be arm64 or x86_64",
            result["failures"],
        )
        self.assertIn(
            "system evidence macOS version is missing or invalid",
            result["failures"],
        )
        self.assertEqual(result["machineModel"], "unavailable")
        self.assertEqual(result["architecture"], "unavailable")
        self.assertEqual(result["macOSVersion"], "unavailable")

    def test_atomic_writer_refuses_to_replace_existing_summary(self) -> None:
        output = self.root / "run.json"
        VALIDATOR.write_atomic_no_replace(output, {"status": "first"})
        original = output.read_bytes()

        with self.assertRaises(FileExistsError):
            VALIDATOR.write_atomic_no_replace(output, {"status": "second"})

        self.assertEqual(output.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
