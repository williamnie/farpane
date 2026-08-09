import json
import subprocess
import unittest
from pathlib import Path


class HostCombinedRoleEvidenceAuditTests(unittest.TestCase):
    def test_item_ten_combined_role_checkpoint_is_frozen(self):
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-combined-role-evidence.py"],
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
            "farpane-host-combined-role-evidence-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["section15_2Item"], 10)
        self.assertEqual(document["status"], "pair-validator-implemented")
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(all(document["remainingBoundary"].values()))

        contract = document["targetContract"]
        self.assertEqual(
            contract["requiredRuns"]["hostReadyViewer"]["scenario"],
            "host-ready-viewer",
        )
        self.assertEqual(
            contract["requiredRuns"]["hostViewerDualActive"]["scenario"],
            "host-viewer-dual",
        )
        self.assertEqual(
            contract["requiredRuns"]["hostReadyViewer"]
            ["minimumConcurrentDurationSeconds"],
            600,
        )
        self.assertTrue(contract["roleIdentity"]["requiresDistinctPIDs"])
        self.assertTrue(
            contract["resourceReporting"]
            ["reportsWindowServerAndMediaAsSharedSystemScope"]
        )
        self.assertEqual(
            contract["resourceReporting"]
            ["readyViewerCombinedAverageCPUCeilingPercent"],
            62.0,
        )
        self.assertEqual(
            contract["resourceReporting"]
            ["dualActiveCombinedAverageCPUCeilingPercent"],
            85.0,
        )
        self.assertIn(
            "scenario-label-without-role-and-overlap-proof",
            contract["forbiddenInference"],
        )
        self.assertTrue(
            contract["pairAggregation"]
            ["requiresExactlyOnePassingAcceptanceRunPerScenario"]
        )
        self.assertTrue(
            contract["pairAggregation"]
            ["requiresSameMachineArchitectureMacOSAndBuild"]
        )
        self.assertTrue(
            contract["pairAggregation"]
            ["doesNotCompleteBroaderV1ConcurrencyRecoveryMatrix"]
        )


if __name__ == "__main__":
    unittest.main()
