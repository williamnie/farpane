import json
from pathlib import Path
import subprocess
import unittest


class HostIdleAuthenticatedConnectionAuthorityAuditTests(unittest.TestCase):
    def test_current_gap_and_shared_target_contract_are_frozen(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-idle-authenticated-connection-authority.py",
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
            "farpane-host-idle-authenticated-connection-authority-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["status"], "checkpoint-required")
        self.assertEqual(document["missingEvidence"], [])

        implementation = document["implementation"]
        self.assertEqual(implementation["hostABIVersion"], 10)
        self.assertEqual(implementation["headerABIVersion"], 10)
        self.assertEqual(implementation["snapshotSchemaVersion"], 7)
        self.assertTrue(all(implementation["evidence"].values()))
        self.assertTrue(all(implementation["sourceLines"].values()))

        target = document["targetContract"]
        self.assertEqual(target["hostABIVersion"], 11)
        self.assertEqual(target["hostSnapshotSchemaVersion"], 8)
        self.assertEqual(target["runtimeStateSchemaVersion"], 2)
        self.assertEqual(
            target["hostSnapshotField"], "authenticatedConnectionCount"
        )
        self.assertFalse(target["xpcOuterWireVersionChangeRequired"])
        self.assertIn(
            "noActiveSessionOrMediaRouteInference", target["countSemantics"]
        )
        self.assertIn(
            "allAuthenticatedConnectionsProvenAbsentDerivedNeverHardcoded",
            target["runtimeStateContract"],
        )
        self.assertTrue(all(document["remainingBoundary"].values()))


if __name__ == "__main__":
    unittest.main()
