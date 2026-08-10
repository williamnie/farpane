import json
import subprocess
import unittest
from pathlib import Path


class HostSleepRecoveryContractAuditTests(unittest.TestCase):
    def test_process_recovery_composition_and_notification_boundary_are_checked(self):
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
        self.assertEqual(document["schemaVersion"], 8)
        self.assertEqual(document["status"], "contract-implemented")
        self.assertEqual(document["missingEvidence"], [])
        implementation = document["implementation"]
        self.assertEqual(implementation["hostABIVersion"], 14)
        self.assertEqual(implementation["snapshotSchemaVersion"], 8)
        self.assertTrue(all(implementation["evidence"].values()))
        self.assertTrue(all(implementation["sourceLines"].values()))

        self.assertEqual(
            implementation["symbols"],
            [
                "rdn_host_begin_sleep",
                "rdn_host_finish_sleep",
                "rdn_host_resume_after_wake",
            ],
        )
        self.assertNotIn(
            "processProjectionOperationsUnbound",
            document["remainingBoundary"],
        )
        self.assertNotIn(
            "processSleepWakeCompositionAbsent",
            document["remainingBoundary"],
        )
        self.assertNotIn(
            "systemSleepWakeNotificationAdapterAbsent",
            document["remainingBoundary"],
        )
        self.assertTrue(
            document["remainingBoundary"][
                "realMacSleepWakeLifecycleEvidenceRequired"
            ]
        )


if __name__ == "__main__":
    unittest.main()
