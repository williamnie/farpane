import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferReceiveRootConfigContractAuditTests(unittest.TestCase):
    def test_receive_root_is_exactly_paired_with_explicit_permission(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-receive-root-config-contract.py",
            ],
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(
            completed.returncode, 0, completed.stderr or completed.stdout
        )
        document = json.loads(completed.stdout)
        self.assertEqual(
            document["schema"],
            "farpane-host-file-transfer-receive-root-config-contract-audit",
        )
        self.assertEqual(
            document["status"],
            "host-file-transfer-receive-root-configured-product-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        implementation = document["implementation"]
        self.assertEqual(implementation["hostABIVersion"], 19)
        self.assertTrue(all(implementation["evidence"].values()))
        self.assertTrue(all(implementation["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["receiveRootConfigImplemented"])
        self.assertFalse(claims["enabledWithoutRootAccepted"])
        self.assertFalse(claims["disabledWithRootAccepted"])
        self.assertFalse(claims["unsafeRootAccepted"])
        self.assertTrue(claims["ownerRetainedForHostLifetime"])
        self.assertTrue(claims["connectionDispatchImplemented"])
        self.assertTrue(claims["nativeNewFileWriteLifecycleImplemented"])
        self.assertTrue(claims["nativeResumeDigestLifecycleImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-native-existing-target-decision-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
