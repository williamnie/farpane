import json
from pathlib import Path
import subprocess
import unittest


class HostV1ConcurrencyEvidenceAuditTests(unittest.TestCase):
    def test_five_case_live_evidence_checkpoint_is_frozen(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-v1-concurrency-evidence.py"],
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
            "farpane-host-v1-concurrency-evidence-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["status"], "checkpoint-required")
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(all(document["remainingBoundary"].values()))
        self.assertEqual(
            document["nextImplementationBoundary"],
            "timestamped-host-viewer-lifecycle-evidence-writer-schema",
        )

        contract = document["targetContract"]
        self.assertEqual(
            contract["requiredScenarioOrder"],
            [
                "hostReadyThenOutboundViewer",
                "viewerThenInboundHost",
                "activeHostViewerStartStop",
                "dualDisconnectRecover",
                "appRestartStableHostID",
            ],
        )
        self.assertEqual(
            contract["requiredScenarios"]["viewerThenInboundHost"]
            ["orderedStates"][0],
            "viewer-authenticated-streaming",
        )
        self.assertTrue(
            contract["requiredScenarios"]["appRestartStableHostID"]
            ["requiresSameHostInstanceScopeDigest"]
        )
        self.assertTrue(
            contract["eventAuthority"]
            ["requiresViewerLifecycleTransitionTimestamps"]
        )
        self.assertTrue(
            contract["aggregation"]
            ["mayReusePassingItemTenPairForResourceAuthorityOnly"]
        )
        self.assertIn(
            "item-ten-overlap-pair-as-full-v1-matrix",
            contract["forbiddenInference"],
        )


if __name__ == "__main__":
    unittest.main()
