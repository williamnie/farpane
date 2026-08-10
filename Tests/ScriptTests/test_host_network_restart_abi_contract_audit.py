import json
import subprocess
import unittest
from pathlib import Path


class HostNetworkRestartABIContractAuditTests(unittest.TestCase):
    def test_current_ownership_and_target_contract_are_frozen(self):
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-network-restart-abi-contract.py",
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
            "farpane-host-network-restart-abi-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 5)
        self.assertEqual(document["status"], "contract-implemented")
        self.assertEqual(document["missingEvidence"], [])

        implementation = document["implementation"]
        self.assertEqual(implementation["hostABIVersion"], 15)
        self.assertEqual(implementation["snapshotSchemaVersion"], 8)
        self.assertTrue(all(implementation["evidence"].values()))
        self.assertTrue(all(implementation["sourceLines"].values()))

        target = document["targetContract"]
        self.assertEqual(target["hostABIVersion"], 15)
        self.assertEqual(target["snapshotSchemaVersion"], 8)
        self.assertEqual(target["symbol"], "rdn_host_recover_network_path")
        self.assertEqual(
            target["generationAuthority"],
            "RdnHost.network_path_generation",
        )
        self.assertEqual(
            target["staleGenerationError"],
            "RDN_HOST_ERR_STALE_GENERATION",
        )
        self.assertIn(
            "returnAcceptedPendingNeverReady",
            target["synchronousSuccessSequence"],
        )
        self.assertIn(
            "sleepRecoveryEpochOrWakelockMutation",
            target["forbiddenSideEffects"],
        )
        self.assertTrue(all(document["remainingBoundary"].values()))


if __name__ == "__main__":
    unittest.main()
