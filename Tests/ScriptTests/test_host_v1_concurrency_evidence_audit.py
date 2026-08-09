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
        self.assertEqual(
            document["status"],
            "host-agent-transition-normalizer-implemented",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(all(document["remainingBoundary"].values()))
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-agent-lossless-observation-publication-seam",
        )
        self.assertTrue(
            document["evidence"]
            ["lifecycleWriterDefinesStrictProcessAndEventSchema"]
        )
        self.assertTrue(
            document["evidence"]
            ["lifecycleWriterBindsOnlySanitizedIdentityAuthority"]
        )
        self.assertTrue(
            document["evidence"]
            ["lifecycleWriterEnforcesRoleAndTerminalStateMachine"]
        )
        self.assertTrue(
            document["evidence"]
            ["lifecycleWriterIsDefaultOffBoundedAndNoOverwrite"]
        )
        self.assertTrue(
            document["evidence"]
            ["applicationProcessOwnerDerivesSanitizedSystemIdentity"]
        )
        self.assertTrue(
            document["evidence"]
            ["applicationProcessOwnerIsDefaultOffAndBestEffort"]
        )
        self.assertTrue(
            document["evidence"]
            ["applicationProcessOwnerRecordsOneTerminalLifecycle"]
        )
        self.assertTrue(
            document["evidence"]
            ["applicationProductOwnsEvidenceAcrossEveryRunExit"]
        )
        self.assertTrue(
            document["evidence"]
            ["applicationViewerOwnerEnforcesEpochAndRecoveryGeneration"]
        )
        self.assertTrue(
            document["evidence"]
            ["applicationViewerOwnerSerializesAndFailsEvidenceOnly"]
        )
        self.assertTrue(
            document["evidence"]
            ["applicationViewerUsesCoreAndTeardownAuthorities"]
        )
        self.assertTrue(
            document["evidence"]
            ["applicationViewerRecoveryRequiresSameEpochCoreStreaming"]
        )
        self.assertTrue(
            document["evidence"]
            ["applicationProjectionCarriesValidatedHostScopeAndRuntime"]
        )
        self.assertTrue(
            document["evidence"]
            ["applicationConfigCoherenceBindsLiveAgentToRevision"]
        )
        self.assertTrue(
            document["evidence"]
            ["hostObservationSchemaRequiresExactAgentProcessIdentity"]
        )
        self.assertTrue(
            document["evidence"]
            ["applicationXPCIdentityOmitsAgentPIDAndProcessStart"]
        )
        self.assertTrue(
            document["evidence"]
            ["applicationHostEvidenceCompositionRemainsFailClosed"]
        )
        self.assertTrue(
            document["evidence"]
            ["hostAgentProcessOwnerUsesPreflightedBuildAndRole"]
        )
        self.assertTrue(
            document["evidence"]
            ["hostAgentProcessOwnerRejectsViewerEventsWithoutFailure"]
        )
        self.assertTrue(
            document["evidence"]
            ["hostAgentProductOwnsEvidenceAcrossRunResult"]
        )
        self.assertTrue(
            document["evidence"]
            ["hostAgentOwnerNormalizesAuthoritativeTransitions"]
        )
        self.assertTrue(
            document["evidence"]
            ["hostAgentRuntimeEvidenceIdentityComesFromLease"]
        )
        self.assertTrue(
            document["evidence"]
            ["hostAgentProductRoutesPostListenerReadyThroughNormalizer"]
        )
        self.assertTrue(
            document["remainingBoundary"]
            ["applicationHostObservationRequiresVersionedAgentProcessIdentity"]
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
