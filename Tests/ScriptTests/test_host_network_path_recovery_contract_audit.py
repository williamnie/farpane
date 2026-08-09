import json
import subprocess
import unittest
from pathlib import Path


class HostNetworkPathRecoveryContractAuditTests(unittest.TestCase):
    def test_trigger_contract_and_product_boundaries_are_explicit(self):
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-network-path-recovery-contract.py",
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
            "farpane-host-network-path-recovery-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 4)
        self.assertEqual(document["status"], "trigger-contract-implemented")
        self.assertEqual(document["missingEvidence"], [])
        self.assertTrue(all(
            document["implementation"]["evidence"].values()
        ))
        self.assertTrue(all(
            document["implementation"]["sourceLines"].values()
        ))
        self.assertTrue(
            document["integrationBoundary"][
                "productNWPathMonitorAdapterAbsent"
            ]
        )
        self.assertTrue(
            document["integrationBoundary"][
                "hostCoreNetworkRecoveryOperationImplemented"
            ]
        )
        self.assertTrue(
            document["integrationBoundary"][
                "swiftReadyConvergenceImplemented"
            ]
        )
        self.assertTrue(
            document["integrationBoundary"][
                "productNetworkRecoveryCompositionImplemented"
            ]
        )


if __name__ == "__main__":
    unittest.main()
