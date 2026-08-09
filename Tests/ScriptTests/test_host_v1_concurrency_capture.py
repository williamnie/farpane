import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "Scripts/run-farpane-host-v1-concurrency-capture.py"
SPEC = importlib.util.spec_from_file_location(
    "run_farpane_host_v1_concurrency_capture", SCRIPT
)
assert SPEC is not None and SPEC.loader is not None
CAPTURE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CAPTURE
SPEC.loader.exec_module(CAPTURE)


class FakeOperations:
    def __init__(self, root: Path, *, kickstart_fails: bool = False) -> None:
        self.root = root
        self.kickstart_fails = kickstart_fails
        self.commands: list[list[str]] = []
        self.spawns: list[tuple[Path, dict[str, str]]] = []
        self.signals: list[int] = []
        self.processes: dict[int, dict[str, object]] = {}
        self.artifacts: dict[int, Path] = {}
        self.next_app_pid = 4201
        self.agent_pid = 4101

    @staticmethod
    def process(pid: int, role: str) -> dict[str, object]:
        return {
            "pid": pid,
            "role": role,
            "executablePath": str(
                CAPTURE.DEFAULT_APP_BUNDLE / "Contents/MacOS/FarPane"
            ),
            "executableSHA256": "a" * 64,
            "bundleIdentifier": "io.rustdesknative.viewer",
            "buildIdentifier": "202608100001",
            "shortVersion": "0.1.0",
            "startMarker": f"start-{pid}",
            "argumentsSHA256": hashlib.sha256(str(pid).encode()).hexdigest(),
            "hostAgentFlagCount": 1 if role == "host-agent" else 0,
            "terminated": False,
        }

    def run(
        self, command: list[str], timeout: float = 15.0
    ) -> CAPTURE.CommandResult:
        del timeout
        self.commands.append(list(command))
        if len(command) > 1 and command[1] == "debug":
            for value in command:
                prefix = f"{CAPTURE.OUTPUT_ENVIRONMENT_KEY}="
                if value.startswith(prefix) and value != prefix:
                    self.artifacts[self.agent_pid] = Path(value[len(prefix):])
        if len(command) > 1 and command[1] == "kickstart":
            if self.kickstart_fails:
                return CAPTURE.CommandResult(1, stderr="injected failure")
            self.processes[self.agent_pid] = self.process(
                self.agent_pid, "host-agent"
            )
            return CAPTURE.CommandResult(0, stdout=f"{self.agent_pid}\n")
        if command and command[0] == sys.executable:
            Path(command[-1]).write_text(
                json.dumps({
                    "schema": "farpane-host-v1-concurrency-result",
                    "schemaVersion": 1,
                    "status": "pass",
                }) + "\n",
                encoding="utf-8",
            )
        return CAPTURE.CommandResult(0)

    def spawn(self, executable: Path, environment: dict[str, str]) -> int:
        pid = self.next_app_pid
        self.next_app_pid += 1
        self.spawns.append((executable, dict(environment)))
        self.processes[pid] = self.process(pid, "viewer")
        self.artifacts[pid] = Path(
            environment[CAPTURE.OUTPUT_ENVIRONMENT_KEY]
        )
        return pid

    def inspect_running_process(
        self, pid: int, role: str
    ) -> dict[str, object]:
        process = self.processes.get(pid)
        if process is None:
            raise CAPTURE.CaptureError(f"cannot verify exact {role} pid={pid}")
        return dict(process)

    def signal_process(self, pid: int) -> None:
        process = self.processes.pop(pid)
        self.signals.append(pid)
        artifact = self.artifacts[pid]
        artifact.write_text(
            json.dumps({
                "observerProcessRole": (
                    "hostAgent"
                    if process["role"] == "host-agent"
                    else "application"
                ),
                "event": {"kind": "processTerminating"},
            })
            + "\n",
            encoding="utf-8",
        )

    def sleep(self, seconds: float) -> None:
        del seconds


class HostV1ConcurrencyCaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(dir=REPOSITORY)
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.scope = CAPTURE.ExecutableScope(
            path=CAPTURE.DEFAULT_APP_BUNDLE / "Contents/MacOS/FarPane",
            sha256="a" * 64,
            bundle_identifier="io.rustdesknative.viewer",
            build_identifier="202608100001",
            short_version="0.1.0",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def start(
        self,
        scenario: str,
        operations: FakeOperations,
    ) -> dict[str, object]:
        return CAPTURE.start_capture(
            self.root,
            scenario,
            operations,
            inspect_bundle=lambda _: self.scope,
        )

    def test_start_scopes_agent_and_app_to_distinct_outputs(self) -> None:
        operations = FakeOperations(self.root)
        scenario = CAPTURE.SCENARIOS[0]

        receipt = self.start(scenario, operations)

        service = f"gui/{os.geteuid()}/{CAPTURE.SERVICE_LABEL}"
        self.assertEqual(receipt["status"], "active")
        self.assertIn(
            [str(CAPTURE.LAUNCHCTL), "print", service], operations.commands
        )
        debug = next(command for command in operations.commands if "debug" in command)
        kickstart = next(
            command for command in operations.commands if "kickstart" in command
        )
        self.assertEqual(debug[2], service)
        self.assertEqual(kickstart[-1], service)
        self.assertNotEqual(
            operations.artifacts[operations.agent_pid],
            operations.artifacts[receipt["applications"][0]["pid"]],
        )
        self.assertEqual(
            operations.spawns[0][1][CAPTURE.SCENARIO_ENVIRONMENT_KEY],
            scenario,
        )
        self.assertFalse(any("setenv" in command for command in operations.commands))
        mode = CAPTURE.receipt_path(self.root, scenario).stat().st_mode & 0o777
        self.assertEqual(mode, 0o600)

    def test_kickstart_failure_clears_one_shot_debug_and_writes_no_receipt(self) -> None:
        operations = FakeOperations(self.root, kickstart_fails=True)
        scenario = CAPTURE.SCENARIOS[0]

        with self.assertRaisesRegex(
            CAPTURE.CaptureError, "cannot restart exact HostAgent service"
        ):
            self.start(scenario, operations)

        debug_commands = [
            command for command in operations.commands if "debug" in command
        ]
        self.assertEqual(len(debug_commands), 2)
        self.assertIn(
            f"{CAPTURE.OUTPUT_ENVIRONMENT_KEY}=", debug_commands[-1]
        )
        self.assertIn(
            f"{CAPTURE.SCENARIO_ENVIRONMENT_KEY}=", debug_commands[-1]
        )
        self.assertFalse(CAPTURE.receipt_path(self.root, scenario).exists())

    def test_restart_and_finish_pin_two_app_lifetimes_and_one_agent(self) -> None:
        operations = FakeOperations(self.root)
        self.start(CAPTURE.RESTART_SCENARIO, operations)

        restarted = CAPTURE.restart_application(self.root, operations)
        completed = CAPTURE.finish_capture(
            self.root, CAPTURE.RESTART_SCENARIO, operations
        )

        self.assertEqual(len(restarted["applications"]), 2)
        self.assertNotEqual(
            restarted["applications"][0]["startMarker"],
            restarted["applications"][1]["startMarker"],
        )
        self.assertEqual(completed["status"], "completed")
        self.assertTrue(completed["agent"]["terminated"])
        self.assertTrue(
            all(app["terminated"] for app in completed["applications"])
        )
        self.assertEqual(operations.signals, [4201, 4202, 4101])

    def test_finish_refuses_reused_pid_without_signalling(self) -> None:
        operations = FakeOperations(self.root)
        scenario = CAPTURE.SCENARIOS[0]
        receipt = self.start(scenario, operations)
        pid = receipt["applications"][0]["pid"]
        operations.processes[pid]["startMarker"] = "reused-process"

        with self.assertRaisesRegex(CAPTURE.CaptureError, "reused pid"):
            CAPTURE.finish_capture(self.root, scenario, operations)

        self.assertEqual(operations.signals, [])

    def test_finish_refuses_scenario_directory_permission_drift(self) -> None:
        operations = FakeOperations(self.root)
        scenario = CAPTURE.SCENARIOS[0]
        self.start(scenario, operations)
        (self.root / scenario).chmod(0o755)

        with self.assertRaisesRegex(CAPTURE.CaptureError, "mode-0700"):
            CAPTURE.finish_capture(self.root, scenario, operations)

        self.assertEqual(operations.signals, [])

    def test_cleanup_of_failed_capture_cannot_be_marked_completed(self) -> None:
        operations = FakeOperations(self.root)
        scenario = CAPTURE.SCENARIOS[0]
        receipt = self.start(scenario, operations)
        receipt["status"] = "restartFailed"
        CAPTURE.replace_receipt(
            CAPTURE.receipt_path(self.root, scenario), receipt
        )

        cleaned = CAPTURE.finish_capture(self.root, scenario, operations)

        self.assertEqual(cleaned["status"], "aborted")
        self.assertTrue(cleaned["agent"]["terminated"])
        self.assertTrue(cleaned["applications"][0]["terminated"])

    def write_completed_receipt(self, scenario: str, index: int) -> None:
        directory = self.root / scenario
        directory.mkdir(mode=0o700)
        app_count = 2 if scenario == CAPTURE.RESTART_SCENARIO else 1
        applications = []
        app_files = []
        for app_index in range(1, app_count + 1):
            process = FakeOperations.process(index * 10 + app_index, "viewer")
            process["terminated"] = True
            applications.append(process)
            filename = f"application-{app_index}.jsonl"
            app_files.append(filename)
            (directory / filename).write_text("app lifecycle\n", encoding="utf-8")
        agent = FakeOperations.process(index * 10 + 9, "host-agent")
        agent["terminated"] = True
        (directory / "host-agent.jsonl").write_text(
            "agent lifecycle\n", encoding="utf-8"
        )
        receipt = {
            "schema": CAPTURE.SCHEMA,
            "schemaVersion": 1,
            "scenario": scenario,
            "status": "completed",
            "serviceTarget": f"gui/{os.geteuid()}/{CAPTURE.SERVICE_LABEL}",
            "applicationBundle": str(CAPTURE.DEFAULT_APP_BUNDLE),
            "expectedExecutable": CAPTURE.expected_executable_document(self.scope),
            "agent": agent,
            "applications": applications,
            "artifacts": {
                "hostAgent": "host-agent.jsonl",
                "applications": app_files,
            },
        }
        CAPTURE.write_new_json(CAPTURE.receipt_path(self.root, scenario), receipt)

    def item_ten_result(self) -> Path:
        path = self.root.parent / f"{self.root.name}-item-10.json"
        path.write_text(
            json.dumps({"scope": {"buildIdentifier": "202608100001"}}) + "\n",
            encoding="utf-8",
        )
        self.addCleanup(path.unlink, missing_ok=True)
        return path

    def test_finalize_hash_binds_completed_receipts_before_validator(self) -> None:
        for index, scenario in enumerate(CAPTURE.SCENARIOS, 1):
            self.write_completed_receipt(scenario, index)
        operations = FakeOperations(self.root)

        result = CAPTURE.finalize_matrix(
            self.root, self.item_ten_result(), operations
        )

        self.assertTrue(result.exists())
        manifest = json.loads(
            (self.root / "v1-concurrency-manifest.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(
            [entry["name"] for entry in manifest["scenarios"]],
            list(CAPTURE.SCENARIOS),
        )
        self.assertEqual(
            [source["role"] for source in manifest["scenarios"][-1]["sources"]],
            ["application", "application", "hostAgent"],
        )
        self.assertEqual(
            manifest["resourceAuthority"]["sha256"],
            hashlib.sha256(
                (self.root / "item-10-pair-result.json").read_bytes()
            ).hexdigest(),
        )

    def test_finalize_does_not_publish_resource_for_incomplete_matrix(self) -> None:
        operations = FakeOperations(self.root)

        with self.assertRaisesRegex(
            CAPTURE.CaptureError, "scenario directory is missing"
        ):
            CAPTURE.finalize_matrix(
                self.root, self.item_ten_result(), operations
            )

        self.assertFalse((self.root / "item-10-pair-result.json").exists())
        self.assertFalse((self.root / "v1-concurrency-manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
