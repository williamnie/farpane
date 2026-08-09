import json
import subprocess
import unittest
from pathlib import Path


class HostSleepRecoveryContractAuditTests(unittest.TestCase):
    def test_pinned_baseline_and_required_contract_are_machine_checked(self):
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-sleep-recovery-contract.py"],
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        document = json.loads(completed.stdout)
        self.assertEqual(document["schema"], "farpane-host-sleep-recovery-contract-audit")
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["status"], "contract-gap-confirmed")
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["baseline"]["hostABIVersion"], 7)
        self.assertEqual(document["baseline"]["snapshotSchemaVersion"], 5)
        self.assertTrue(all(document["baseline"]["evidence"].values()))
        self.assertTrue(all(document["baseline"]["sourceLines"].values()))

        contract = document["requiredContract"]
        self.assertEqual(contract["targetHostABIVersion"], 8)
        self.assertEqual(contract["targetSnapshotSchemaVersion"], 6)
        self.assertEqual(
            contract["symbols"],
            [
                "rdn_host_begin_sleep",
                "rdn_host_finish_sleep",
                "rdn_host_resume_after_wake",
            ],
        )
        self.assertIn("exact epoch", contract["registrationConvergence"])
        self.assertIn("Rust wakelock thread", contract["assertionOwnership"])
        self.assertEqual(
            contract["snapshotFields"],
            ["recoveryEpoch", "recoveryStatus", "registrationStatus"],
        )


if __name__ == "__main__":
    unittest.main()
