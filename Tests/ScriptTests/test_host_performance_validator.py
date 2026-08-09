import csv
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class HostPerformanceValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.repository = Path(__file__).resolve().parents[2]
        self.validator = (
            self.repository / "Scripts/validate-farpane-host-performance.py"
        )
        self.scenario = "stability-1080p30"
        self.duration = 6
        self.route_path = self.root / "route.json"
        self.system_path = self.root / "system.json"
        self.samples_path = self.root / "samples.csv"
        self.output_path = self.root / "run.json"
        self.route = self._route_fixture()
        self._write_route()
        self._write_system()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _route_fixture(self) -> dict:
        drop_reasons = (
            "captureSuperseded",
            "encoderBackpressure",
            "networkBackpressure",
            "reconfigure",
            "invalidFrame",
            "shutdown",
        )
        drops = {
            reason: {"instrumented": True, "count": 0}
            for reason in drop_reasons
        }
        drops.update({"classified": 0, "unclassified": 0, "total": 0})
        return {
            "schema": "farpane-media-telemetry",
            "schemaVersion": 7,
            "runtimeSeconds": float(self.duration),
            "media": {
                "requestedWidth": 1_920,
                "requestedHeight": 1_080,
                "captureWidth": 1_920,
                "captureHeight": 1_080,
                "requestedFramesPerSecond": 30,
                "hardwareAccelerated": True,
                "softwareFallback": False,
            },
            "capture": {
                "validFrames": 120,
                "actualFramesPerSecond": 20.0,
                "maximumLogicalRawFrameCopyCount": 1,
                "rawFrameQueueDepth": 0,
                "maximumRawFrameQueueDepth": 2,
            },
            "encode": {"packets": 120, "inFlight": 0},
            "send": {
                "accepted": 120,
                "dropped": 0,
                "encodedQueueSamples": 6,
                "encodedQueueDepth": 0,
                "maximumEncodedQueueDepth": 2,
                "encodedQueueCapacity": 3,
                "encodedQueueFinalized": True,
            },
            "writer": {
                "metricSamples": 6,
                "cycles": 120,
                "subscriberDispatches": 120,
                "dispatchWallTotalMicroseconds": 12_000,
                "maximumDispatchWallMicroseconds": 200,
                "confirmationWaitTotalMicroseconds": 24_000,
                "maximumConfirmationWaitMicroseconds": 300,
                "completedConfirmations": 120,
                "timedOutConfirmations": 0,
                "finalized": True,
            },
            "network": {
                "metricSamples": 6,
                "subscriberCount": 1,
                "qosSubscriberCount": 1,
                "delaySampledSubscribers": 1,
                "rttSampledSubscribers": 1,
                "responseDelayedSubscribers": 0,
                "latestNetworkDelayMilliseconds": 20,
                "maximumNetworkDelayMilliseconds": 25,
                "latestRoundTripTimeMilliseconds": 30,
                "maximumRoundTripTimeMilliseconds": 35,
                "finalized": True,
            },
            "transport": {
                "metricSamples": 6,
                "subscriberCount": 1,
                "directSubscribers": 0,
                "relaySubscribers": 1,
                "unknownSubscribers": 0,
                "finalized": True,
            },
            "drops": drops,
            "cadence": {
                "contentState": "high",
                "targetFramesPerSecond": 30,
                "appliedFramesPerSecond": 30,
                "dirtyMetadataTrusted": True,
                "configurationUpdatesApplied": 1,
                "configurationUpdateFailures": 0,
                "configurationUpdateCancellations": 0,
                "configurationUpdateInFlight": False,
            },
            "process": {"samples": 6},
        }

    def _write_route(self) -> None:
        self.route_path.write_text(json.dumps(self.route), encoding="utf-8")

    def _write_system(
        self,
        *,
        host_cpu: list[float] | None = None,
        sample_mode: str = "smoke",
        schema_version: int = 3,
        sample_started_at: str | None = None,
        sample_completed_at: str | None = None,
    ) -> None:
        document = {
            "schemaVersion": schema_version,
            "sampler": "farpane-host-system",
            "scenario": self.scenario,
            "sampleMode": sample_mode,
            "requestedDurationSeconds": self.duration,
            "sampleCount": self.duration,
            "completed": True,
            "samplerExitStatus": 0,
            "machineModel": "Macmini9,1",
            "architecture": "arm64",
            "macOSVersion": "15.6",
        }
        if sample_started_at is not None:
            document["sampleStartedAt"] = sample_started_at
        if sample_completed_at is not None:
            document["collectedAt"] = sample_completed_at
        self.system_path.write_text(
            json.dumps(document),
            encoding="utf-8",
        )
        cpu_values = host_cpu or [10.0] * self.duration
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
            for index, cpu in enumerate(cpu_values):
                writer.writerow(
                    {
                        "elapsed_seconds": index,
                        "scenario": self.scenario,
                        "host_cpu_percent": cpu,
                        "host_rss_kb": 100_000,
                        "host_threads": 12,
                        "windowserver_cpu_percent": 3.0,
                        "videotoolboxd_cpu_percent": 0.5,
                        "vt_encoder_xpc_cpu_percent": 0.5,
                        "host_sleep_assertion_count": 1,
                        "host_user_idle_sleep_assertion_count": 1,
                        "host_display_sleep_assertion_count": 0,
                    }
                )

    def _run(
        self,
        recovery_source: Path | None = None,
        recovery_sequence: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        arguments = [
            sys.executable,
            str(self.validator),
            self.scenario,
            str(self.duration),
            str(self.route_path),
            str(self.system_path),
            str(self.samples_path),
            str(self.output_path),
        ]
        if recovery_source is not None and recovery_sequence is not None:
            arguments.extend([str(recovery_source), str(recovery_sequence)])
        return subprocess.run(
            arguments,
            cwd=self.repository,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_accepts_complete_stability_smoke_fixture(self) -> None:
        completed = self._run()

        self.assertEqual(
            completed.returncode,
            0,
            completed.stderr or completed.stdout,
        )
        result = json.loads(self.output_path.read_text(encoding="utf-8"))
        self.assertEqual(result["schema"], "farpane-host-performance-run")
        self.assertEqual(result["schemaVersion"], 4)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["failures"], [])
        self.assertEqual(result["machineModel"], "Macmini9,1")
        self.assertEqual(result["architecture"], "arm64")
        self.assertEqual(result["macOSVersion"], "15.6")
        self.assertEqual(result["stabilityWindowCount"], 6)
        self.assertEqual(
            result["stabilityDropCounts"],
            {
                "captureSuperseded": 0,
                "encoderBackpressure": 0,
                "networkBackpressure": 0,
                "reconfigure": 0,
                "invalidFrame": 0,
                "shutdown": 0,
            },
        )

    def test_rejects_material_sustained_cpu_rise(self) -> None:
        self._write_system(host_cpu=[1.0, 2.0, 3.0, 4.0, 5.0, 6.0])

        completed = self._run()

        self.assertEqual(completed.returncode, 1)
        result = json.loads(self.output_path.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "fail")
        self.assertTrue(result["stabilityHostCPUSustainedRise"])
        self.assertIn(
            "Host CPU has a material sustained rise across all six stability windows",
            result["failures"],
        )

    def test_rejects_incomplete_stability_drop_ledger(self) -> None:
        del self.route["drops"]["reconfigure"]
        self._write_route()

        completed = self._run()

        self.assertEqual(completed.returncode, 1)
        result = json.loads(self.output_path.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "fail")
        self.assertIn(
            "stability route drop reason reconfigure is not fully instrumented",
            result["failures"],
        )

    def test_rejects_short_acceptance_labeled_as_thirty_minutes(self) -> None:
        self._write_system(sample_mode="acceptance")

        completed = self._run()

        self.assertEqual(completed.returncode, 1)
        result = json.loads(self.output_path.read_text(encoding="utf-8"))
        self.assertEqual(result["status"], "fail")
        self.assertIn(
            "stability acceptance evidence is shorter than 1800 seconds",
            result["failures"],
        )

    def test_rejects_missing_or_unsupported_machine_identity(self) -> None:
        system = json.loads(self.system_path.read_text(encoding="utf-8"))
        del system["machineModel"]
        system["architecture"] = "future-architecture"
        system["macOSVersion"] = "15.6\nforged"
        self.system_path.write_text(json.dumps(system), encoding="utf-8")

        completed = self._run()

        self.assertEqual(completed.returncode, 1)
        result = json.loads(self.output_path.read_text(encoding="utf-8"))
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

    def test_refuses_to_replace_existing_run_evidence(self) -> None:
        first = self._run()
        self.assertEqual(first.returncode, 0, first.stderr or first.stdout)
        original = self.output_path.read_bytes()

        second = self._run()

        self.assertEqual(second.returncode, 2)
        self.assertIn("refusing to overwrite", second.stderr)
        self.assertEqual(self.output_path.read_bytes(), original)

    def test_binds_recovery_record_before_full_1080p30_acceptance_window(self) -> None:
        self.scenario = "1080p30"
        self.duration = 600
        self.route = self._route_fixture()
        self._write_route()
        self._write_system(
            sample_mode="acceptance",
            schema_version=4,
            sample_started_at="2026-08-10T01:00:00Z",
            sample_completed_at="2026-08-10T01:10:00Z",
        )
        transition = {
            "schema": "farpane-host-recovery-transition",
            "schemaVersion": 1,
            "sequence": 1,
            "kind": "sleepWake",
            "acceptedAt": "2026-08-10T00:58:00Z",
            "completedAt": "2026-08-10T00:59:00Z",
            "acceptedMonotonicNanoseconds": 100,
            "completedMonotonicNanoseconds": 200,
            "status": "completed",
            "hostInstanceScopeSHA256": "a" * 64,
            "buildIdentitySHA256": "b" * 64,
            "correlation": {
                "recoveryEpoch": 1,
                "runningReadyConverged": True,
            },
        }
        raw_record = json.dumps(
            transition, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        transition_path = self.root / "recovery.jsonl"
        transition_path.write_bytes(raw_record + b"\n")

        completed = self._run(transition_path, 1)

        self.assertEqual(
            completed.returncode,
            0,
            completed.stderr or completed.stdout,
        )
        result = json.loads(self.output_path.read_text(encoding="utf-8"))
        self.assertEqual(result["schemaVersion"], 5)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["sampleStartedAt"], "2026-08-10T01:00:00Z")
        self.assertEqual(result["sampleCompletedAt"], "2026-08-10T01:10:00Z")
        self.assertEqual(result["recoveryTransition"], {
            "kind": "sleepWake",
            "sequence": 1,
            "recordSHA256": hashlib.sha256(raw_record).hexdigest(),
            "completedAt": "2026-08-10T00:59:00Z",
            "hostInstanceScopeSHA256": "a" * 64,
            "buildIdentitySHA256": "b" * 64,
        })


if __name__ == "__main__":
    unittest.main()
