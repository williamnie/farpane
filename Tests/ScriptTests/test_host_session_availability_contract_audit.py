import json
import subprocess
import unittest
from pathlib import Path


class HostSessionAvailabilityContractAuditTests(unittest.TestCase):
    def test_current_gap_and_target_contract_are_frozen(self):
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-session-availability-contract.py",
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
            "farpane-host-session-availability-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["status"], "contract-gap-confirmed")
        self.assertEqual(document["missingEvidence"], [])

        implementation = document["implementation"]
        self.assertEqual(implementation["hostABIVersion"], 9)
        self.assertEqual(implementation["snapshotSchemaVersion"], 6)
        self.assertTrue(all(implementation["evidence"].values()))
        self.assertTrue(all(implementation["sourceLines"].values()))

        target = document["targetContract"]
        self.assertEqual(target["hostABIVersion"], 10)
        self.assertEqual(target["snapshotSchemaVersion"], 7)
        self.assertEqual(
            target["singleAuthority"],
            "pinned Rust active Aqua CGSession policy",
        )
        self.assertEqual(
            target["topLevelTuple"]["limited"],
            {
                "sessionAvailability": "limited",
                "sessionUnavailableReason": "sessionUnavailable",
            },
        )
        self.assertIn(
            "withdrawBackgroundReadyAndApprovalActions",
            target["transitionSequence"],
        )
        self.assertIn(
            "inputInjectionWhileLimited",
            target["forbiddenSideEffects"],
        )
        self.assertTrue(all(document["remainingBoundary"].values()))


if __name__ == "__main__":
    unittest.main()
