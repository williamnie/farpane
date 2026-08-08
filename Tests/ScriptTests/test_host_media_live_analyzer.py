from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
ANALYZER_PATH = REPO_ROOT / "Scripts" / "analyze-farpane-host-media-live.py"
SPEC = importlib.util.spec_from_file_location(
    "analyze_farpane_host_media_live", ANALYZER_PATH
)
assert SPEC is not None and SPEC.loader is not None
ANALYZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYZER)


class HostMediaLiveAnalyzerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.log_path = self.root / "host-media.jsonl"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _captured_at(self, seconds: int) -> str:
        return datetime.fromtimestamp(
            1_700_000_000 + seconds, timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%SZ")

    def _record(
        self,
        sequence: int,
        event: str,
        *,
        target_fps: int = 15,
        applied_fps: int = 15,
        content_state: str = "highMotion",
        applied_pressure: str = "moderate",
        observed_pressure: str = "moderate",
        causes: list[str] | None = None,
    ) -> dict:
        if causes is None:
            causes = ["networkDelay"] if observed_pressure != "none" else []
        return {
            "schema": "farpane-host-media-live",
            "schemaVersion": 1,
            "sequence": sequence,
            "capturedAt": self._captured_at(sequence),
            "monotonicNanoseconds": sequence * 1_000_000_000,
            "event": event,
            "recentWindowSeconds": 5,
            "codec": "h264",
            "requestedFPS": 30,
            "recentCaptureFPS": 20.5,
            "recentEncodedFPS": 20.25,
            "recentRustAdmissionFPS": 20.0,
            "captureAverageFPS": 19.5,
            "captureTargetFPS": target_fps,
            "captureAppliedFPS": applied_fps,
            "captureContentState": content_state,
            "captureDirtyMetadataTrusted": False,
            "captureAppliedPressureLevel": applied_pressure,
            "captureObservedPressureLevel": observed_pressure,
            "capturePressureCauses": causes,
            "captureConfigurationUpdateInFlight": target_fps != applied_fps,
            "encodeInFlight": 0,
            "recentSendOutcomeCount": 32,
            "recentSendDropRate": 0.0,
            "consecutiveSendDrops": 0,
            "networkDelayMS": 180 if "networkDelay" in causes else 80,
            "responseDelayedSubscribers": 0,
            "runtimeSeconds": float(sequence),
        }

    def _valid_records(self) -> list[dict]:
        return [
            self._record(1, "routeStarted"),
            self._record(2, "periodic"),
            self._record(3, "periodic"),
            self._record(
                4,
                "periodic",
                target_fps=30,
                applied_fps=15,
                content_state="interactive",
                applied_pressure="moderate",
                observed_pressure="none",
                causes=[],
            ),
            self._record(
                5,
                "routeStopped",
                target_fps=30,
                applied_fps=30,
                content_state="interactive",
                applied_pressure="none",
                observed_pressure="none",
                causes=[],
            ),
        ]

    def _write(self, records: list[dict]) -> None:
        self.log_path.write_text(
            "".join(json.dumps(record) + "\n" for record in records),
            encoding="utf-8",
        )

    def test_validates_and_summarizes_stage_alignment_and_pressure_regimes(self) -> None:
        self._write(self._valid_records())

        result = ANALYZER.analyze(self.log_path)

        self.assertEqual(result["validationStatus"], "pass")
        self.assertEqual(result["performanceVerdict"], "diagnostic-only")
        self.assertEqual(result["recordCount"], 5)
        self.assertEqual(result["periodicSampleCount"], 3)
        self.assertEqual(result["durationSeconds"], 2.0)
        self.assertEqual(result["pressureCauseSamples"], {"networkDelay": 2})
        self.assertEqual(result["cadenceSamples"], {"15/15": 2, "30/15": 1})
        self.assertEqual(
            result["medianAbsoluteStageDeltaFPS"],
            {"captureToEncode": 0.25, "encodeToRustAdmission": 0.25},
        )
        self.assertEqual(len(result["regimes"]), 2)
        self.assertEqual(result["regimes"][0]["pressureCauses"], ["networkDelay"])
        self.assertEqual(result["regimes"][1]["observedPressure"], "none")

    def test_fails_closed_on_sequence_unknown_field_and_missing_final_event(self) -> None:
        records = self._valid_records()[:-1]
        records[2]["sequence"] = 30
        records[2]["password"] = "must-not-be-accepted"
        self._write(records)

        result = ANALYZER.analyze(self.log_path)

        self.assertEqual(result["validationStatus"], "fail")
        self.assertIn("record sequence is not contiguous from one", result["failures"])
        self.assertIn("last record is not a final lifecycle event", result["failures"])
        self.assertTrue(
            any("unknown fields: password" in failure for failure in result["failures"])
        )
        self.assertNotIn("regimes", result)

    def test_rejects_nonfinite_json_and_periodic_count_above_bound(self) -> None:
        malformed = json.dumps(self._record(1, "routeStarted")) + "\n"
        malformed += '{"recentCaptureFPS":NaN}\n'
        self.log_path.write_text(malformed, encoding="utf-8")
        malformed_result = ANALYZER.analyze(self.log_path)
        self.assertEqual(malformed_result["validationStatus"], "fail")
        self.assertIn("line 2 is invalid JSON", malformed_result["failures"])

        records = [self._record(1, "routeStarted")]
        records.extend(
            self._record(index + 2, "periodic")
            for index in range(ANALYZER.MAXIMUM_PERIODIC_RECORDS + 1)
        )
        records.append(self._record(len(records) + 1, "routeStopped"))
        self._write(records)
        bounded_result = ANALYZER.analyze(self.log_path)
        self.assertEqual(bounded_result["validationStatus"], "fail")
        self.assertIn(
            "periodic sample count exceeds the per-route bound",
            bounded_result["failures"],
        )

    def test_atomic_output_refuses_to_replace_existing_analysis(self) -> None:
        output = self.root / "analysis.json"
        ANALYZER.write_atomic_no_replace(output, {"validationStatus": "pass"})
        original = output.read_bytes()

        with self.assertRaises(FileExistsError):
            ANALYZER.write_atomic_no_replace(
                output, {"validationStatus": "different"}
            )

        self.assertEqual(output.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
