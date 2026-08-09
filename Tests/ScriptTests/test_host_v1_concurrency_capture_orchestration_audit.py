import json
from pathlib import Path
import subprocess
import unittest


class HostV1ConcurrencyCaptureOrchestrationAuditTests(unittest.TestCase):
    def test_installed_capture_orchestrator_implements_frozen_contract(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-v1-concurrency-capture-orchestration.py",
            ],
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(
            completed.returncode,
            0,
            completed.stderr or completed.stdout,
        )
        document = json.loads(completed.stdout)
        self.assertEqual(
            document["schema"],
            "farpane-host-v1-concurrency-capture-orchestration-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "capture-orchestrator-implemented",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertFalse(
            document["remainingBoundary"]
            ["captureOrchestratorStillRequiresImplementation"]
        )
        self.assertEqual(
            document["nextImplementationBoundary"],
            "installed-v1-concurrency-five-scenario-execution",
        )

        contract = document["targetContract"]
        self.assertEqual(
            contract["launchAgentInjection"]["mechanism"],
            "launchctl-debug-next-invocation-environment",
        )
        self.assertTrue(
            contract["launchAgentInjection"]
            ["requiresExplicitOperatorInvocation"]
        )
        self.assertTrue(
            contract["launchAgentInjection"]
            ["mustVerifyReturnedPIDAndExactHostAgentArguments"]
        )
        self.assertIn(
            "launchctl-setenv-global-user-environment",
            contract["forbiddenMutation"],
        )
        self.assertIn(
            "editing-signed-launch-agent-plist",
            contract["forbiddenMutation"],
        )


if __name__ == "__main__":
    unittest.main()
