import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferExplicitPolicyABIContractAuditTests(unittest.TestCase):
    def test_file_transfer_is_abi_capable_but_product_default_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-explicit-policy-abi-contract.py",
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
            "farpane-host-file-transfer-explicit-policy-abi-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "host-file-transfer-abi-capable-product-default-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        implementation = document["implementation"]
        self.assertEqual(implementation["hostABIVersion"], 16)
        self.assertTrue(all(implementation["evidence"].values()))
        self.assertTrue(all(implementation["sourceLines"].values()))
        self.assertFalse(document["claims"]["hostFileTransferEnabledByDefault"])
        self.assertTrue(document["claims"]["hostFileTransferABICapable"])
        self.assertFalse(document["claims"]["hostFileTransferProductEnabled"])
        self.assertFalse(document["claims"]["viewerFileTransferImplemented"])
        self.assertFalse(document["claims"]["filePromiseClipboardEnabled"])
        self.assertFalse(document["claims"]["installedTwoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-security-boundary-audit",
        )


if __name__ == "__main__":
    unittest.main()
