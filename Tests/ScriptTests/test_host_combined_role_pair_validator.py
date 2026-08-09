import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "Scripts/validate-farpane-host-combined-role-pair.py"
SPEC = importlib.util.spec_from_file_location(
    "validate_farpane_host_combined_role_pair", SCRIPT_PATH
)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VALIDATOR
SPEC.loader.exec_module(VALIDATOR)


class HostCombinedRolePairValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(dir=REPO_ROOT)
        self.root = Path(self.temporary_directory.name)
        self.manifest_path = self.root / "pair-manifest.json"
        self.output_path = self.root / "pair-result.json"
        self.make_fixture()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    @staticmethod
    def digest(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    @staticmethod
    def scope() -> dict[str, object]:
        return {
            "machineModel": "Macmini10,1",
            "architecture": "arm64",
            "macOSVersion": "15.6",
            "bundleIdentifier": "io.rustdesknative.viewer",
            "buildIdentifier": "202608100001",
            "shortVersion": "0.1.0",
            "executableSHA256": "a" * 64,
        }

    @staticmethod
    def sources(prefix: str) -> dict[str, object]:
        names = sorted(VALIDATOR.SOURCE_NAMES)
        return {
            name: {
                "path": f"{prefix}/{name}.evidence",
                "sha256": hashlib.sha256(
                    f"{prefix}:{name}".encode("utf-8")
                ).hexdigest(),
                "byteCount": index + 1,
            }
            for index, name in enumerate(names)
        }

    def run_document(self, scenario: str) -> dict[str, object]:
        dual = scenario == "host-viewer-dual"
        duration = 600
        return {
            "schema": VALIDATOR.RUN_SCHEMA,
            "schemaVersion": 1,
            "scenario": scenario,
            "sampleMode": "acceptance",
            "requestedDurationSeconds": duration,
            "status": "pass",
            "failures": [],
            "scope": self.scope(),
            "sources": self.sources(scenario),
            "thresholds": VALIDATOR.SCENARIO_THRESHOLDS[scenario],
            "metrics": {
                "system": {
                    "sampleCount": duration,
                    "maximumSampleGapSeconds": 1.0,
                    "hostAgentAverageCPUPercent": 10.0 if dual else 1.0,
                    "viewerAverageCPUPercent": 10.0,
                    "combinedAverageCPUPercent": 20.0 if dual else 11.0,
                    "hostAgentPeakRSSKB": 10_000,
                    "viewerPeakRSSKB": 20_000,
                    "hostAgentPeakThreads": 10,
                    "viewerPeakThreads": 20,
                },
                "hostRuntimeState": {
                    "sourceRecordCount": 603,
                    "coveredRecordCount": 601,
                    "maximumCoveredGapSeconds": 1.0,
                },
                "viewer": {
                    "processID": 202,
                    "durationSeconds": 602.0,
                    "encodedFrames": 12_000,
                    "decodedFrames": 12_000,
                    "presentedFrames": 11_900,
                    "maximumPresentationGapMilliseconds": 1_000.0,
                },
            },
            "claims": {
                "exactRoleAndBuildIdentityBound": True,
                "hostRuntimeStateBound": True,
                "viewerContinuousPresentationBound": True,
                "individualAndCombinedCPUThresholdEvaluated": True,
                "scenarioEvidenceComplete": True,
                "section15_2Item10Complete": False,
            },
        }

    def make_fixture(self) -> None:
        ready = self.root / "ready.json"
        dual = self.root / "dual.json"
        ready.write_text(
            json.dumps(self.run_document("host-ready-viewer"), sort_keys=True) + "\n",
            encoding="utf-8",
        )
        dual.write_text(
            json.dumps(self.run_document("host-viewer-dual"), sort_keys=True) + "\n",
            encoding="utf-8",
        )
        manifest = {
            "schema": VALIDATOR.MANIFEST_SCHEMA,
            "schemaVersion": 1,
            "runs": {
                "hostReadyViewer": {
                    "path": ready.name,
                    "sha256": self.digest(ready),
                },
                "hostViewerDual": {
                    "path": dual.name,
                    "sha256": self.digest(dual),
                },
            },
        }
        self.manifest_path.write_text(
            json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8"
        )

    def mutate_run(self, name: str, mutation) -> None:
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        path = self.root / manifest["runs"][name]["path"]
        run = json.loads(path.read_text(encoding="utf-8"))
        mutation(run)
        path.write_text(json.dumps(run, sort_keys=True) + "\n", encoding="utf-8")
        manifest["runs"][name]["sha256"] = self.digest(path)
        self.manifest_path.write_text(
            json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8"
        )

    def test_accepts_two_complete_acceptance_runs_in_one_scope(self) -> None:
        result = VALIDATOR.validate(self.manifest_path)

        self.assertEqual(result["status"], "pass", result["failures"])
        self.assertEqual(result["failures"], [])
        self.assertEqual(result["scope"], self.scope())
        self.assertEqual(
            result["requirements"],
            {"host-ready-viewer": "pass", "host-viewer-dual": "pass"},
        )
        self.assertTrue(result["claims"]["bothAcceptanceScenariosComplete"])
        self.assertTrue(result["claims"]["sameMachineBuildMacOSScope"])
        self.assertTrue(result["claims"]["section15_2Item10Complete"])
        self.assertFalse(result["claims"]["v1ConcurrencyRecoveryMatrixComplete"])

    def test_rejects_smoke_short_failed_or_incomplete_run(self) -> None:
        def mutation(run: dict[str, object]) -> None:
            run["sampleMode"] = "smoke"
            run["requestedDurationSeconds"] = 60
            run["status"] = "fail"
            run["failures"] = ["source failed"]
            run["metrics"]["system"]["sampleCount"] = 60
            run["claims"]["scenarioEvidenceComplete"] = False

        self.mutate_run("hostReadyViewer", mutation)
        result = VALIDATOR.validate(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        self.assertFalse(result["claims"]["section15_2Item10Complete"])
        self.assertTrue(any("not acceptance" in value for value in result["failures"]))
        self.assertTrue(any("duration" in value for value in result["failures"]))
        self.assertTrue(any("did not pass" in value for value in result["failures"]))
        self.assertTrue(any("scenarioEvidenceComplete" in value for value in result["failures"]))

    def test_rejects_machine_or_build_scope_drift(self) -> None:
        def mutation(run: dict[str, object]) -> None:
            run["scope"]["machineModel"] = "MacBookPro18,3"
            run["scope"]["buildIdentifier"] = "202608100002"

        self.mutate_run("hostViewerDual", mutation)
        result = VALIDATOR.validate(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["scope"], {})
        self.assertIn(
            "pair runs do not share one machine/build/macOS scope",
            result["failures"],
        )
        self.assertFalse(result["claims"]["sameMachineBuildMacOSScope"])

    def test_rejects_scenario_threshold_and_metric_tampering(self) -> None:
        def mutation(run: dict[str, object]) -> None:
            run["scenario"] = "host-ready-viewer"
            run["thresholds"]["combinedAverageCPUCeilingPercent"] = 90.0
            run["metrics"]["system"]["combinedAverageCPUPercent"] = 90.0

        self.mutate_run("hostViewerDual", mutation)
        result = VALIDATOR.validate(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        self.assertTrue(any("scenario is invalid" in value for value in result["failures"]))
        self.assertTrue(any("thresholds" in value for value in result["failures"]))
        self.assertTrue(any("combinedAverageCPUPercent" in value for value in result["failures"]))

    def test_rejects_hash_escape_symlink_and_hardlink_inputs(self) -> None:
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["runs"]["hostViewerDual"]["sha256"] = "f" * 64
        self.manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(VALIDATOR.PairValidationError, "SHA-256"):
            VALIDATOR.validate(self.manifest_path)

        self.make_fixture()
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["runs"]["hostViewerDual"]["path"] = "../dual.json"
        self.manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(VALIDATOR.PairValidationError, "unsafe"):
            VALIDATOR.validate(self.manifest_path)

        self.make_fixture()
        dual = self.root / "dual.json"
        linked = self.root / "linked.json"
        linked.symlink_to(dual.name)
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["runs"]["hostViewerDual"] = {
            "path": linked.name,
            "sha256": self.digest(dual),
        }
        self.manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(VALIDATOR.PairValidationError, "symlink"):
            VALIDATOR.validate(self.manifest_path)

        linked.unlink()
        duplicate = self.root / "duplicate.json"
        duplicate.hardlink_to(dual)
        manifest["runs"]["hostViewerDual"] = {
            "path": duplicate.name,
            "sha256": self.digest(dual),
        }
        self.manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(VALIDATOR.PairValidationError, "identity or size"):
            VALIDATOR.validate(self.manifest_path)

    def test_malformed_types_fail_without_crashing(self) -> None:
        def mutation(run: dict[str, object]) -> None:
            run["requestedDurationSeconds"] = True
            run["scope"]["architecture"] = 7
            run["metrics"]["viewer"]["durationSeconds"] = "600"

        self.mutate_run("hostReadyViewer", mutation)
        result = VALIDATOR.validate(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        self.assertFalse(result["claims"]["section15_2Item10Complete"])

    def test_cli_publishes_once_and_refuses_overwrite(self) -> None:
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
        self.assertTrue(
            json.loads(self.output_path.read_text(encoding="utf-8"))["claims"]
            ["section15_2Item10Complete"]
        )
        self.assertEqual(second.returncode, 2)
        self.assertIn("refusing to overwrite", second.stderr)


if __name__ == "__main__":
    unittest.main()
