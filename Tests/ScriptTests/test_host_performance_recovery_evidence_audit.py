import json
import subprocess
import unittest
from pathlib import Path


class HostPerformanceRecoveryEvidenceAuditTests(unittest.TestCase):
    def test_item_seven_recovery_evidence_checkpoint_is_frozen(self):
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-performance-recovery-evidence.py",
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
            "farpane-host-performance-recovery-evidence-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["status"], "writer-implemented")
        self.assertEqual(document["section15_2Item"], 7)
        self.assertEqual(document["missingEvidence"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(all(document["remainingBoundary"].values()))

        contract = document["targetContract"]
        self.assertEqual(
            contract["transitionEvidence"]["requiredKinds"],
            ["sleepWake", "networkPath", "displayReconfigure"],
        )
        manifest = contract["repetitionManifest"]
        self.assertEqual(manifest["requiredTransitionCount"], 3)
        self.assertEqual(manifest["requiredRunCount"], 3)
        self.assertEqual(manifest["requiredPostRecoveryScenario"], "1080p30")
        self.assertEqual(manifest["minimumPostRecoveryDurationSeconds"], 600)
        self.assertIn(
            "media-reconfigure-drop-count",
            contract["forbiddenInference"],
        )


if __name__ == "__main__":
    unittest.main()
