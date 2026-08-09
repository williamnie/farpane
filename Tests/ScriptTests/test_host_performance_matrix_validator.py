import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
VALIDATOR_PATH = REPO_ROOT / "Scripts" / "validate-farpane-host-performance-matrix.py"
SPEC = importlib.util.spec_from_file_location(
    "validate_farpane_host_performance_matrix", VALIDATOR_PATH
)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class HostPerformanceMatrixValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.run_paths: list[str] = []
        for architecture, model in (
            ("arm64", "Macmini9,1"),
            ("x86_64", "MacBookPro11,3"),
        ):
            for scenario in (
                "host-ready-no-screen-route",
                "static-1080p30",
                "1080p30",
                "4k30-normal",
                "4k30-video",
                "stability-1080p30",
            ):
                path = f"{architecture}-{scenario}.run.json"
                self.run_paths.append(path)
                self._write_run(path, architecture, model, scenario)
        self.manifest_path = self.root / "matrix.manifest.json"
        self._write_manifest(self.run_paths)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _run_document(
        self, architecture: str, model: str, scenario: str
    ) -> dict:
        if scenario == "host-ready-no-screen-route":
            return {
                "schema": "farpane-host-idle-run",
                "schemaVersion": 1,
                "scenario": scenario,
                "sampleMode": "acceptance",
                "requestedDurationSeconds": 600,
                "machineModel": model,
                "architecture": architecture,
                "macOSVersion": "15.6",
                "allAuthenticatedConnectionsProvenAbsent": True,
                "status": "pass",
                "failures": [],
                "collectedAt": "2026-08-09T00:00:00Z",
            }
        profile = "stability" if scenario.startswith("stability-") else (
            "connected-static" if scenario.startswith("static-") else "active"
        )
        return {
            "schema": "farpane-host-performance-run",
            "schemaVersion": 4,
            "scenario": scenario,
            "performanceProfile": profile,
            "sampleMode": "acceptance",
            "requestedDurationSeconds": (
                1_800 if profile == "stability" else 600
            ),
            "machineModel": model,
            "architecture": architecture,
            "macOSVersion": "15.6",
            "status": "pass",
            "failures": [],
            "collectedAt": "2026-08-09T00:00:00Z",
        }

    def _write_run(
        self, path: str, architecture: str, model: str, scenario: str
    ) -> None:
        (self.root / path).write_text(
            json.dumps(self._run_document(architecture, model, scenario)),
            encoding="utf-8",
        )

    def _write_manifest(self, paths: list[str]) -> None:
        self.manifest_path.write_text(
            json.dumps(
                {
                    "schema": "farpane-host-base-performance-matrix-manifest",
                    "schemaVersion": 1,
                    "runs": paths,
                }
            ),
            encoding="utf-8",
        )

    def test_accepts_complete_dual_architecture_base_matrix(self) -> None:
        result = VALIDATOR.validate_matrix(self.manifest_path)

        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["failures"], [])
        self.assertEqual(len(result["sources"]), 12)
        self.assertFalse(result["fullSection15_2Complete"])
        self.assertEqual(result["uncoveredSection15_2Items"], [7, 9, 10])
        for architecture in ("arm64", "x86_64"):
            self.assertTrue(
                all(
                    status == "pass"
                    for status in result["requirements"][architecture].values()
                )
            )
        self.assertTrue(
            all(len(source["sha256"]) == 64 for source in result["sources"])
        )

    def test_rejects_missing_intel_stability_run(self) -> None:
        paths = [
            path
            for path in self.run_paths
            if path != "x86_64-stability-1080p30.run.json"
        ]
        self._write_manifest(paths)

        result = VALIDATOR.validate_matrix(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        self.assertIn(
            "matrix manifest must contain exactly 12 run summaries",
            result["failures"],
        )
        self.assertIn(
            "x86_64 matrix requirement stability-30-minute is missing",
            result["failures"],
        )

    def test_rejects_smoke_failed_or_incomplete_idle_authority(self) -> None:
        source_path = self.root / "arm64-host-ready-no-screen-route.run.json"
        source = json.loads(source_path.read_text(encoding="utf-8"))
        source["sampleMode"] = "smoke"
        source["status"] = "fail"
        source["failures"] = ["synthetic failure"]
        source["allAuthenticatedConnectionsProvenAbsent"] = False
        source_path.write_text(json.dumps(source), encoding="utf-8")

        result = VALIDATOR.validate_matrix(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        invalid_source = next(
            source
            for source in result["sources"]
            if source["path"] == "arm64-host-ready-no-screen-route.run.json"
        )
        self.assertEqual(invalid_source["status"], "invalid")
        self.assertIn(
            "idle evidence does not prove all authenticated connections absent",
            invalid_source["failures"],
        )
        self.assertIn(
            "run summary is not acceptance evidence", invalid_source["failures"]
        )
        self.assertIn(
            "arm64 matrix requirement host-idle is missing", result["failures"]
        )

    def test_rejects_machine_or_macos_drift_within_architecture(self) -> None:
        source_path = self.root / "arm64-4k30-video.run.json"
        source = json.loads(source_path.read_text(encoding="utf-8"))
        source["machineModel"] = "MacBookPro18,3"
        source["macOSVersion"] = "16.0"
        source_path.write_text(json.dumps(source), encoding="utf-8")

        result = VALIDATOR.validate_matrix(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        self.assertIn(
            "arm64 matrix mixes multiple machine models", result["failures"]
        )
        self.assertIn(
            "arm64 matrix mixes multiple macOS versions", result["failures"]
        )

    def test_rejects_malformed_source_types_without_crashing(self) -> None:
        source_path = self.root / "arm64-1080p30.run.json"
        source = json.loads(source_path.read_text(encoding="utf-8"))
        source["scenario"] = {"forged": True}
        source["architecture"] = ["arm64"]
        source["requestedDurationSeconds"] = True
        source["collectedAt"] = "not-a-timestamp"
        source_path.write_text(json.dumps(source), encoding="utf-8")

        result = VALIDATOR.validate_matrix(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        invalid_source = next(
            source
            for source in result["sources"]
            if source["path"] == "arm64-1080p30.run.json"
        )
        self.assertEqual(invalid_source["status"], "invalid")
        self.assertEqual(invalid_source["scenario"], "unavailable")
        self.assertEqual(invalid_source["architecture"], "unavailable")
        self.assertEqual(invalid_source["requestedDurationSeconds"], 0)
        self.assertEqual(invalid_source["collectedAt"], "unavailable")

    def test_rejects_path_escape_and_duplicate_source(self) -> None:
        paths = list(self.run_paths)
        paths[0] = "../outside.run.json"
        paths[1] = paths[2]
        self._write_manifest(paths)

        result = VALIDATOR.validate_matrix(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        self.assertIn(
            "run 1 path is not a safe relative JSON path", result["failures"]
        )
        self.assertIn(
            "run 3 duplicates an earlier source path", result["failures"]
        )

    def test_atomic_writer_refuses_to_replace_existing_summary(self) -> None:
        output_path = self.root / "matrix.run.json"
        VALIDATOR.write_atomic_no_replace(output_path, {"status": "first"})
        original = output_path.read_bytes()

        with self.assertRaises(FileExistsError):
            VALIDATOR.write_atomic_no_replace(output_path, {"status": "second"})

        self.assertEqual(output_path.read_bytes(), original)

    def test_cli_publishes_once_and_refuses_overwrite(self) -> None:
        output_path = self.root / "matrix.cli.run.json"
        first = subprocess.run(
            [str(VALIDATOR_PATH), str(self.manifest_path), str(output_path)],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(first.returncode, 0, first.stderr or first.stdout)
        self.assertIn("full_section_15_2_complete=false", first.stdout)
        published = json.loads(output_path.read_text(encoding="utf-8"))
        self.assertEqual(published["status"], "pass")
        original = output_path.read_bytes()

        second = subprocess.run(
            [str(VALIDATOR_PATH), str(self.manifest_path), str(output_path)],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(second.returncode, 2)
        self.assertIn("refusing to overwrite", second.stderr)
        self.assertEqual(output_path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
