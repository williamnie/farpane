from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "Scripts/validate-farpane-host-v1-concurrency.py"
SPEC = importlib.util.spec_from_file_location(
    "validate_farpane_host_v1_concurrency", SCRIPT_PATH
)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VALIDATOR
SPEC.loader.exec_module(VALIDATOR)


class HostV1ConcurrencyValidatorTests(unittest.TestCase):
    build_identifier = "202608100001"
    application_build = VALIDATOR.build_identity_digest(build_identifier)
    agent_build = VALIDATOR.build_identity_digest(build_identifier)
    host_scope = "e" * 64

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(dir=REPO_ROOT)
        self.root = Path(self.temporary_directory.name)
        self.manifest_path = self.root / "v1-manifest.json"
        self.output_path = self.root / "v1-concurrency-result.json"
        self.make_fixture()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    @staticmethod
    def digest(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    @staticmethod
    def scenario_digest(name: str) -> str:
        return hashlib.sha256(name.encode("utf-8")).hexdigest()

    @staticmethod
    def timestamp(monotonic: int) -> str:
        value = datetime(2026, 8, 10, tzinfo=timezone.utc) + timedelta(
            microseconds=monotonic
        )
        return value.isoformat(timespec="microseconds").replace("+00:00", "Z")

    def host_event(
        self,
        state: str,
        agent_pid: int,
        agent_start: str,
        agent_boot: str,
        generation: int = 0,
    ) -> dict[str, object]:
        return {
            "kind": "hostState",
            "state": state,
            "hostInstanceScopeSHA256": self.host_scope,
            "agentBootID": agent_boot,
            "configRevision": 7,
            "hostAgentProcessID": agent_pid,
            "hostAgentProcessStartIdentitySHA256": agent_start,
            "hostAgentBuildIdentitySHA256": self.agent_build,
            "transitionGeneration": generation,
        }

    @staticmethod
    def viewer_event(
        state: str, epoch: int = 1, generation: int = 0
    ) -> dict[str, object]:
        return {
            "kind": "viewerState",
            "state": state,
            "sessionEpoch": epoch,
            "transitionGeneration": generation,
        }

    def write_lifecycle(
        self,
        filename: str,
        role: str,
        process_id: int,
        process_start: str,
        build: str,
        scenario: str,
        events: list[tuple[int, dict[str, object]]],
    ) -> Path:
        path = self.root / filename
        all_events = [(events[0][0] - 5, {"kind": "processStarted"})]
        all_events.extend(events)
        all_events.append((events[-1][0] + 10, {"kind": "processTerminating"}))
        records = []
        for sequence, (monotonic, event) in enumerate(all_events, 1):
            records.append({
                "schema": VALIDATOR.LIFECYCLE_SCHEMA,
                "schemaVersion": 1,
                "sequence": sequence,
                "capturedAt": self.timestamp(monotonic),
                "monotonicNanoseconds": monotonic,
                "observerProcessRole": role,
                "observerProcessID": process_id,
                "observerProcessStartIdentitySHA256": process_start,
                "observerBuildIdentitySHA256": build,
                "scenarioCorrelationSHA256": self.scenario_digest(scenario),
                "event": event,
            })
        path.write_text(
            "".join(json.dumps(record, sort_keys=True) + "\n" for record in records),
            encoding="utf-8",
        )
        return path

    def make_fixture(self) -> None:
        resource_scope = {
            "machineModel": "Macmini10,1",
            "architecture": "arm64",
            "macOSVersion": "15.6",
            "bundleIdentifier": "io.rustdesknative.viewer",
            "buildIdentifier": self.build_identifier,
            "shortVersion": "0.1.0",
            "executableSHA256": "c" * 64,
        }
        resource_path = self.root / "item-10-pair-result.json"
        resource_path.write_text(json.dumps({
            "schema": VALIDATOR.RESOURCE_AUTHORITY_SCHEMA,
            "schemaVersion": 1,
            "coverageScope": "section-15.2-item-10",
            "status": "pass",
            "failures": [],
            "scope": resource_scope,
            "requirements": {
                "host-ready-viewer": "pass",
                "host-viewer-dual": "pass",
            },
            "runs": {
                "hostReadyViewer": {
                    "scenario": "host-ready-viewer",
                    "requestedDurationSeconds": 600,
                    "scope": resource_scope,
                    "path": "host-ready-viewer.run.json",
                    "sha256": hashlib.sha256(b"host-ready-viewer").hexdigest(),
                    "byteCount": 1_024,
                },
                "hostViewerDual": {
                    "scenario": "host-viewer-dual",
                    "requestedDurationSeconds": 600,
                    "scope": resource_scope,
                    "path": "host-viewer-dual.run.json",
                    "sha256": hashlib.sha256(b"host-viewer-dual").hexdigest(),
                    "byteCount": 2_048,
                },
            },
            "claims": {
                "bothAcceptanceScenariosComplete": True,
                "sameMachineBuildMacOSScope": True,
                "section15_2Item10Complete": True,
                "v1ConcurrencyRecoveryMatrixComplete": False,
            },
            "collectedAt": "2026-08-10T00:00:00Z",
        }, sort_keys=True) + "\n", encoding="utf-8")
        scenario_entries = []
        for scenario_index, name in enumerate(VALIDATOR.SCENARIO_NAMES, 1):
            base = scenario_index * 10_000
            agent_pid = 5_000 + scenario_index
            agent_start = hashlib.sha256(f"agent-{name}".encode()).hexdigest()
            agent_boot = f"00000000-0000-0000-0000-{scenario_index:012d}"
            app_start = hashlib.sha256(f"app-{name}".encode()).hexdigest()
            if name == "hostReadyThenOutboundViewer":
                app_events = [
                    (base + 20, self.host_event("readyZeroInbound", agent_pid, agent_start, agent_boot)),
                    (base + 30, self.viewer_event("starting")),
                    (base + 40, self.viewer_event("authenticatedStreaming")),
                    (base + 50, self.host_event("readyZeroInbound", agent_pid, agent_start, agent_boot)),
                    (base + 60, self.viewer_event("stopped")),
                ]
                agent_events = [
                    (base + 10, self.host_event("readyZeroInbound", agent_pid, agent_start, agent_boot)),
                ]
            elif name == "viewerThenInboundHost":
                app_events = [
                    (base + 20, self.viewer_event("starting")),
                    (base + 30, self.viewer_event("authenticatedStreaming")),
                    (base + 50, self.host_event("inboundMediaActive", agent_pid, agent_start, agent_boot)),
                    (base + 60, self.viewer_event("stopped")),
                ]
                agent_events = [
                    (base + 10, self.host_event("readyZeroInbound", agent_pid, agent_start, agent_boot)),
                    (base + 40, self.host_event("inboundMediaActive", agent_pid, agent_start, agent_boot)),
                ]
            elif name == "activeHostViewerStartStop":
                app_events = [
                    (base + 20, self.host_event("inboundMediaActive", agent_pid, agent_start, agent_boot)),
                    (base + 30, self.viewer_event("starting")),
                    (base + 40, self.viewer_event("authenticatedStreaming")),
                    (base + 50, self.viewer_event("stopped")),
                    (base + 60, self.host_event("inboundMediaActive", agent_pid, agent_start, agent_boot)),
                ]
                agent_events = [
                    (base + 10, self.host_event("inboundMediaActive", agent_pid, agent_start, agent_boot)),
                ]
            elif name == "dualDisconnectRecover":
                app_events = [
                    (base + 20, self.host_event("inboundMediaActive", agent_pid, agent_start, agent_boot)),
                    (base + 25, self.viewer_event("starting")),
                    (base + 30, self.viewer_event("authenticatedStreaming")),
                    (base + 40, self.viewer_event("disconnected", generation=1)),
                    (base + 45, self.host_event("disconnected", agent_pid, agent_start, agent_boot, 1)),
                    (base + 50, self.viewer_event("recoveredStreaming", generation=1)),
                    (base + 55, self.host_event("recoveredInboundMediaActive", agent_pid, agent_start, agent_boot, 1)),
                    (base + 65, self.viewer_event("stopped")),
                    (base + 70, self.host_event("recoveredReadyZeroInbound", agent_pid, agent_start, agent_boot, 1)),
                ]
                agent_events = [
                    (base + 10, self.host_event("inboundMediaActive", agent_pid, agent_start, agent_boot)),
                    (base + 42, self.host_event("disconnected", agent_pid, agent_start, agent_boot, 1)),
                    (base + 52, self.host_event("recoveredInboundMediaActive", agent_pid, agent_start, agent_boot, 1)),
                    (base + 60, self.host_event("recoveredReadyZeroInbound", agent_pid, agent_start, agent_boot, 1)),
                ]
            else:
                first_app = self.write_lifecycle(
                    f"{scenario_index}-app-first.jsonl", "application", 6_001,
                    hashlib.sha256(b"app-restart-first").hexdigest(),
                    self.application_build, name,
                    [(base + 20, self.host_event("readyZeroInbound", agent_pid, agent_start, agent_boot))],
                )
                second_app = self.write_lifecycle(
                    f"{scenario_index}-app-second.jsonl", "application", 6_002,
                    hashlib.sha256(b"app-restart-second").hexdigest(),
                    self.application_build, name,
                    [(base + 60, self.host_event("readyZeroInbound", agent_pid, agent_start, agent_boot))],
                )
                agent = self.write_lifecycle(
                    f"{scenario_index}-agent.jsonl", "hostAgent", agent_pid,
                    agent_start, self.agent_build, name,
                    [(base + 10, self.host_event("readyZeroInbound", agent_pid, agent_start, agent_boot)),
                     (base + 80, self.host_event("readyZeroInbound", agent_pid, agent_start, agent_boot))],
                )
                # Extend the Agent lifetime so it brackets both complete App lifetimes.
                agent_records = [json.loads(line) for line in agent.read_text(encoding="utf-8").splitlines()]
                agent_records[-1]["capturedAt"] = self.timestamp(base + 100)
                agent_records[-1]["monotonicNanoseconds"] = base + 100
                agent.write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in agent_records), encoding="utf-8")
                paths = [("application", first_app), ("application", second_app), ("hostAgent", agent)]
                scenario_entries.append({
                    "name": name,
                    "sources": [
                        {"role": role, "path": path.name, "sha256": self.digest(path)}
                        for role, path in paths
                    ],
                })
                continue

            app = self.write_lifecycle(
                f"{scenario_index}-app.jsonl", "application", 6_000 + scenario_index,
                app_start, self.application_build, name, app_events,
            )
            agent = self.write_lifecycle(
                f"{scenario_index}-agent.jsonl", "hostAgent", agent_pid,
                agent_start, self.agent_build, name, agent_events,
            )
            agent_records = [
                json.loads(line)
                for line in agent.read_text(encoding="utf-8").splitlines()
            ]
            agent_records[-1]["capturedAt"] = self.timestamp(base + 100)
            agent_records[-1]["monotonicNanoseconds"] = base + 100
            agent.write_text(
                "".join(
                    json.dumps(record, sort_keys=True) + "\n"
                    for record in agent_records
                ),
                encoding="utf-8",
            )
            scenario_entries.append({
                "name": name,
                "sources": [
                    {"role": "application", "path": app.name, "sha256": self.digest(app)},
                    {"role": "hostAgent", "path": agent.name, "sha256": self.digest(agent)},
                ],
            })

        manifest = {
            "schema": VALIDATOR.MANIFEST_SCHEMA,
            "schemaVersion": 1,
            "scope": {
                **resource_scope,
                "applicationBuildIdentitySHA256": self.application_build,
                "hostAgentBuildIdentitySHA256": self.agent_build,
            },
            "resourceAuthority": {
                "path": resource_path.name,
                "sha256": self.digest(resource_path),
            },
            "scenarios": scenario_entries,
        }
        self.manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")

    def mutate_source(self, scenario_name: str, role_index: int, mutation) -> None:
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        scenario = next(item for item in manifest["scenarios"] if item["name"] == scenario_name)
        reference = scenario["sources"][role_index]
        path = self.root / reference["path"]
        records = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
        mutation(records)
        path.write_text("".join(json.dumps(record, sort_keys=True) + "\n" for record in records), encoding="utf-8")
        reference["sha256"] = self.digest(path)
        self.manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")

    def test_accepts_exact_five_ordered_scenarios(self) -> None:
        result = VALIDATOR.validate(self.manifest_path)

        self.assertEqual(result["status"], "pass", result["failures"])
        self.assertEqual(result["failures"], [])
        self.assertEqual(result["requirements"], {name: "pass" for name in VALIDATOR.SCENARIO_NAMES})
        self.assertTrue(result["claims"]["v1ConcurrencyMatrixComplete"])
        self.assertTrue(result["claims"]["sameHostInstanceScopeAcrossMatrix"])
        self.assertTrue(result["claims"]["installedTwoMachineExecutionBound"])

    def test_rejects_missing_or_reordered_scenario_and_unsafe_source(self) -> None:
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["scenarios"] = manifest["scenarios"][:-1]
        self.manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(VALIDATOR.V1ConcurrencyValidationError, "exactly five"):
            VALIDATOR.validate(self.manifest_path)

        self.make_fixture()
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["scenarios"][0], manifest["scenarios"][1] = manifest["scenarios"][1], manifest["scenarios"][0]
        self.manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(VALIDATOR.V1ConcurrencyValidationError, "scenario order"):
            VALIDATOR.validate(self.manifest_path)

        self.make_fixture()
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["scenarios"][0]["sources"][0]["path"] = "../outside.jsonl"
        self.manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(VALIDATOR.V1ConcurrencyValidationError, "unsafe"):
            VALIDATOR.validate(self.manifest_path)

    def test_rejects_noncontiguous_sequence_identity_drift_and_wrong_build(self) -> None:
        self.mutate_source(
            "hostReadyThenOutboundViewer", 0,
            lambda records: records[2].__setitem__("sequence", 99),
        )
        result = VALIDATOR.validate(self.manifest_path)
        self.assertEqual(result["status"], "fail")
        self.assertTrue(any("sequence" in failure for failure in result["failures"]))

        self.make_fixture()
        self.mutate_source(
            "viewerThenInboundHost", 0,
            lambda records: records[2].__setitem__("observerProcessStartIdentitySHA256", "f" * 64),
        )
        result = VALIDATOR.validate(self.manifest_path)
        self.assertTrue(any("identity drifted" in failure for failure in result["failures"]))

        self.make_fixture()
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        reference = manifest["scenarios"][0]["sources"][0]
        source_path = self.root / reference["path"]
        source_path.write_text(
            source_path.read_text(encoding="utf-8").replace(
                '"schemaVersion": 1',
                '"schemaVersion": 1, "schemaVersion": 1',
                1,
            ),
            encoding="utf-8",
        )
        reference["sha256"] = self.digest(source_path)
        self.manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        result = VALIDATOR.validate(self.manifest_path)
        self.assertTrue(any("invalid strict JSON" in failure for failure in result["failures"]))

        self.make_fixture()
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["scope"]["applicationBuildIdentitySHA256"] = "f" * 64
        self.manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(
            VALIDATOR.V1ConcurrencyValidationError,
            "build identity",
        ):
            VALIDATOR.validate(self.manifest_path)

    def test_rejects_scenario_ordering_host_only_recovery_and_fake_restart(self) -> None:
        self.mutate_source(
            "activeHostViewerStartStop", 0,
            lambda records: records.__setitem__(
                5,
                {**records[5], "event": self.viewer_event("stopped")},
            ),
        )
        result = VALIDATOR.validate(self.manifest_path)
        self.assertEqual(result["requirements"]["activeHostViewerStartStop"], "fail")

        self.make_fixture()
        self.mutate_source(
            "dualDisconnectRecover", 0,
            lambda records: records.__setitem__(
                6,
                {**records[6], "event": self.viewer_event("stopped")},
            ),
        )
        result = VALIDATOR.validate(self.manifest_path)
        self.assertEqual(result["requirements"]["dualDisconnectRecover"], "fail")
        self.assertFalse(result["claims"]["v1ConcurrencyMatrixComplete"])

        self.make_fixture()
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        scenario = manifest["scenarios"][-1]
        first_path = self.root / scenario["sources"][0]["path"]
        second_path = self.root / scenario["sources"][1]["path"]
        first_start = json.loads(first_path.read_text(encoding="utf-8").splitlines()[0])[
            "observerProcessStartIdentitySHA256"
        ]
        records = [json.loads(line) for line in second_path.read_text(encoding="utf-8").splitlines()]
        for record in records:
            record["observerProcessStartIdentitySHA256"] = first_start
        second_path.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
        scenario["sources"][1]["sha256"] = self.digest(second_path)
        self.manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        result = VALIDATOR.validate(self.manifest_path)
        self.assertEqual(result["requirements"]["appRestartStableHostID"], "fail")
        self.assertTrue(any("two ordered App lifetimes" in failure for failure in result["failures"]))

    def test_rejects_hash_mismatch_duplicate_hardlink_and_host_scope_drift(self) -> None:
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest["scenarios"][0]["sources"][0]["sha256"] = "f" * 64
        self.manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(VALIDATOR.V1ConcurrencyValidationError, "SHA-256"):
            VALIDATOR.validate(self.manifest_path)

        self.make_fixture()
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        resource_path = self.root / manifest["resourceAuthority"]["path"]
        resource = json.loads(resource_path.read_text(encoding="utf-8"))
        resource["claims"]["section15_2Item10Complete"] = False
        resource_path.write_text(json.dumps(resource) + "\n", encoding="utf-8")
        manifest["resourceAuthority"]["sha256"] = self.digest(resource_path)
        self.manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(
            VALIDATOR.V1ConcurrencyValidationError,
            "claims",
        ):
            VALIDATOR.validate(self.manifest_path)

        self.make_fixture()
        manifest = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        source = self.root / manifest["scenarios"][0]["sources"][0]["path"]
        duplicate = self.root / "duplicate.jsonl"
        duplicate.hardlink_to(source)
        manifest["scenarios"][1]["sources"][0] = {
            "role": "application", "path": duplicate.name, "sha256": self.digest(duplicate)
        }
        self.manifest_path.write_text(json.dumps(manifest) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(VALIDATOR.V1ConcurrencyValidationError, "identity or size|duplicate"):
            VALIDATOR.validate(self.manifest_path)

        duplicate.unlink()
        self.make_fixture()
        self.mutate_source(
            "viewerThenInboundHost", 0,
            lambda records: records[3]["event"].__setitem__("hostInstanceScopeSHA256", "f" * 64),
        )
        result = VALIDATOR.validate(self.manifest_path)
        self.assertEqual(result["status"], "fail")
        self.assertTrue(any(
            "Host scope drifted" in failure or "identity does not match" in failure
            for failure in result["failures"]
        ))

    def test_cli_publishes_once_and_refuses_overwrite(self) -> None:
        command = [sys.executable, str(SCRIPT_PATH), str(self.manifest_path), str(self.output_path)]

        first = subprocess.run(command, check=False, capture_output=True, text=True)
        second = subprocess.run(command, check=False, capture_output=True, text=True)

        self.assertEqual(first.returncode, 0, first.stderr or first.stdout)
        result = json.loads(self.output_path.read_text(encoding="utf-8"))
        self.assertTrue(result["claims"]["v1ConcurrencyMatrixComplete"])
        self.assertEqual(second.returncode, 2)
        self.assertIn("refusing to overwrite", second.stderr)


if __name__ == "__main__":
    unittest.main()
