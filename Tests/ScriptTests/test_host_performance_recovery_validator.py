import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
VALIDATOR_PATH = (
    REPO_ROOT / "Scripts/validate-farpane-host-performance-recovery.py"
)
SPEC = importlib.util.spec_from_file_location(
    "validate_farpane_host_performance_recovery", VALIDATOR_PATH
)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class HostPerformanceRecoveryValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.scope_digest = "a" * 64
        self.build_digest = "b" * 64
        self.transition_path = self.root / "recovery.jsonl"
        self.manifest_path = self.root / "recovery.manifest.json"
        self.run_paths = {
            "sleepWake": self.root / "sleep.run.json",
            "networkPath": self.root / "network.run.json",
            "displayReconfigure": self.root / "display.run.json",
        }
        self.records = self._records()
        self._write_transition_source()
        self._write_runs()
        self._write_manifest()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _records(self) -> list[dict]:
        common = {
            "schema": "farpane-host-recovery-transition",
            "schemaVersion": 1,
            "status": "completed",
            "hostInstanceScopeSHA256": self.scope_digest,
            "buildIdentitySHA256": self.build_digest,
        }
        return [
            {
                **common,
                "sequence": 1,
                "kind": "sleepWake",
                "acceptedAt": "2026-08-10T00:00:00Z",
                "completedAt": "2026-08-10T00:01:00Z",
                "acceptedMonotonicNanoseconds": 100,
                "completedMonotonicNanoseconds": 200,
                "correlation": {
                    "recoveryEpoch": 1,
                    "runningReadyConverged": True,
                },
            },
            {
                **common,
                "sequence": 2,
                "kind": "networkPath",
                "acceptedAt": "2026-08-10T00:11:00Z",
                "completedAt": "2026-08-10T00:12:00Z",
                "acceptedMonotonicNanoseconds": 300,
                "completedMonotonicNanoseconds": 400,
                "correlation": {
                    "pathGeneration": 1,
                    "recoveryEpoch": 1,
                    "runningReadyConverged": True,
                },
            },
            {
                **common,
                "sequence": 3,
                "kind": "displayReconfigure",
                "acceptedAt": "2026-08-10T00:22:00Z",
                "completedAt": "2026-08-10T00:23:00Z",
                "acceptedMonotonicNanoseconds": 500,
                "completedMonotonicNanoseconds": 600,
                "correlation": {
                    "previousDisplayRevision": 1,
                    "replacementDisplayRevision": 2,
                    "previousConnectionEpoch": 10,
                    "replacementConnectionEpoch": 11,
                    "previousCodecEpoch": 20,
                    "replacementCodecEpoch": 21,
                    "freshRouteConverged": True,
                },
            },
        ]

    def _raw_record(self, record: dict) -> bytes:
        return json.dumps(
            record, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")

    def _write_transition_source(self) -> None:
        self.transition_path.write_bytes(
            b"".join(self._raw_record(record) + b"\n" for record in self.records)
        )

    def _run_document(self, record: dict, start_minute: int) -> dict:
        raw_record = self._raw_record(record)
        started_at = f"2026-08-10T00:{start_minute:02d}:00Z"
        completed_hour = 1 if start_minute >= 50 else 0
        completed_minute = (start_minute + 10) % 60
        completed_at = (
            f"2026-08-10T{completed_hour:02d}:{completed_minute:02d}:00Z"
        )
        return {
            "schema": "farpane-host-performance-run",
            "schemaVersion": 5,
            "scenario": "1080p30",
            "performanceProfile": "active",
            "sampleMode": "acceptance",
            "requestedDurationSeconds": 600,
            "machineModel": "Macmini9,1",
            "architecture": "arm64",
            "macOSVersion": "15.6",
            "sampleStartedAt": started_at,
            "sampleCompletedAt": completed_at,
            "status": "pass",
            "failures": [],
            "collectedAt": completed_at,
            "recoveryTransition": {
                "kind": record["kind"],
                "sequence": record["sequence"],
                "recordSHA256": hashlib.sha256(raw_record).hexdigest(),
                "completedAt": record["completedAt"],
                "hostInstanceScopeSHA256": self.scope_digest,
                "buildIdentitySHA256": self.build_digest,
            },
        }

    def _write_runs(self) -> None:
        for record, start_minute in zip(self.records, (2, 13, 24)):
            self.run_paths[record["kind"]].write_text(
                json.dumps(self._run_document(record, start_minute)),
                encoding="utf-8",
            )

    def _write_manifest(self) -> None:
        self.manifest_path.write_text(
            json.dumps({
                "schema": "farpane-host-performance-recovery-manifest",
                "schemaVersion": 1,
                "transitionSource": {
                    "path": self.transition_path.name,
                    "sha256": hashlib.sha256(
                        self.transition_path.read_bytes()
                    ).hexdigest(),
                },
                "runs": [
                    {
                        "path": path.name,
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    }
                    for path in self.run_paths.values()
                ],
            }),
            encoding="utf-8",
        )

    def _rewrite_run(self, kind: str, mutation) -> None:
        path = self.run_paths[kind]
        document = json.loads(path.read_text(encoding="utf-8"))
        mutation(document)
        path.write_text(json.dumps(document), encoding="utf-8")
        self._write_manifest()

    def test_accepts_exact_three_recoveries_and_post_recovery_runs(self) -> None:
        result = VALIDATOR.validate_manifest(self.manifest_path)

        self.assertEqual(result["status"], "pass", result["failures"])
        self.assertTrue(result["fullSection15_2Item7Complete"])
        self.assertEqual(
            result["requirements"],
            {
                "sleepWake": "pass",
                "networkPath": "pass",
                "displayReconfigure": "pass",
            },
        )
        self.assertEqual(result["hostInstanceScopeSHA256"], self.scope_digest)
        self.assertEqual(result["buildIdentitySHA256"], self.build_digest)
        self.assertEqual(len(result["sources"]), 3)

    def test_rejects_path_escape_and_duplicate_run_source(self) -> None:
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["runs"][0]["path"] = "../outside.run.json"
        manifest["runs"][1] = dict(manifest["runs"][2])
        self.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        result = VALIDATOR.validate_manifest(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        self.assertIn("run 3 duplicates an earlier source path", result["failures"])
        invalid = next(
            source for source in result["sources"]
            if source["path"] == "../outside.run.json"
        )
        self.assertIn("path is not a safe relative source path", invalid["failures"])

    def test_rejects_symlink_source(self) -> None:
        link = self.root / "linked.run.json"
        link.symlink_to(self.run_paths["sleepWake"])
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["runs"][0] = {
            "path": link.name,
            "sha256": hashlib.sha256(link.read_bytes()).hexdigest(),
        }
        self.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        result = VALIDATOR.validate_manifest(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        linked = next(source for source in result["sources"] if source["path"] == link.name)
        self.assertIn("source path contains a symlink", linked["failures"])

    def test_rejects_source_hash_mismatch(self) -> None:
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["transitionSource"]["sha256"] = "c" * 64
        manifest["runs"][0]["sha256"] = "d" * 64
        self.manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        result = VALIDATOR.validate_manifest(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        self.assertIn(
            "transition source failed recovery admission", result["failures"]
        )
        self.assertIn(
            "run source digest does not match manifest",
            result["sources"][0]["failures"],
        )

    def test_rejects_scope_drift_and_wrong_transition_binding(self) -> None:
        self._rewrite_run(
            "networkPath",
            lambda document: document["recoveryTransition"].update({
                "kind": "sleepWake",
                "hostInstanceScopeSHA256": "c" * 64,
            }),
        )

        result = VALIDATOR.validate_manifest(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        self.assertTrue(any(
            "binding does not match its transition" in failure
            for failure in result["failures"]
        ))
        self.assertIn(
            "recovery runs must cover sleepWake, networkPath, and displayReconfigure exactly once",
            result["failures"],
        )

    def test_rejects_run_that_started_before_recovery_completed(self) -> None:
        self._rewrite_run(
            "displayReconfigure",
            lambda document: document.update({
                "sampleStartedAt": "2026-08-10T00:22:30Z",
                "sampleCompletedAt": "2026-08-10T00:32:30Z",
                "collectedAt": "2026-08-10T00:32:30Z",
            }),
        )

        result = VALIDATOR.validate_manifest(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        display = next(
            source for source in result["sources"]
            if source["path"] == self.run_paths["displayReconfigure"].name
        )
        self.assertIn(
            "run did not start after its recovery completed", display["failures"]
        )

    def test_rejects_malformed_transition_and_run_types(self) -> None:
        self.records[2]["correlation"]["replacementDisplayRevision"] = 1
        self._write_transition_source()
        self._rewrite_run(
            "sleepWake",
            lambda document: document.update({
                "requestedDurationSeconds": True,
            }),
        )
        self._write_manifest()

        result = VALIDATOR.validate_manifest(self.manifest_path)

        self.assertEqual(result["status"], "fail")
        self.assertIn(
            "transition source failed recovery admission", result["failures"]
        )
        sleep = next(
            source for source in result["sources"]
            if source["path"] == self.run_paths["sleepWake"].name
        )
        self.assertIn("run duration is shorter than 600 seconds", sleep["failures"])

    def test_atomic_writer_refuses_existing_output(self) -> None:
        output = self.root / "result.json"
        VALIDATOR.write_atomic_no_replace(output, {"status": "first"})
        original = output.read_bytes()

        with self.assertRaises(FileExistsError):
            VALIDATOR.write_atomic_no_replace(output, {"status": "second"})

        self.assertEqual(output.read_bytes(), original)

    def test_cli_publishes_once_and_refuses_overwrite(self) -> None:
        output = self.root / "recovery.result.json"
        first = subprocess.run(
            [str(VALIDATOR_PATH), str(self.manifest_path), str(output)],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(first.returncode, 0, first.stderr or first.stdout)
        self.assertIn("section_15_2_item_7_complete=true", first.stdout)
        original = output.read_bytes()

        second = subprocess.run(
            [str(VALIDATOR_PATH), str(self.manifest_path), str(output)],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(second.returncode, 2)
        self.assertIn("refusing to overwrite", second.stderr)
        self.assertEqual(output.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
