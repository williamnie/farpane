import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferViewerUploadSemanticReadABIContractAuditTests(
    unittest.TestCase
):
    def test_current_repository_reports_semantic_read_with_product_action(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-viewer-upload-semantic-read-abi-contract.py",
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
            document["status"],
            "viewer-upload-semantic-read-abi-implemented-product-on",
        )
        self.assertTrue(all(document["evidence"].values()))
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        claims = document["claims"]
        self.assertTrue(claims["viewerABIV14Implemented"])
        self.assertFalse(claims["pathOrDescriptorCrossesABI"])
        self.assertTrue(claims["swiftDescriptorReadAuthorityImplemented"])
        self.assertTrue(claims["rustSemanticUploadJobImplemented"])
        self.assertTrue(claims["viewerUploadWireImplemented"])
        self.assertTrue(claims["viewerUploadProductActionImplemented"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-installed-single-mac-smoke",
        )


if __name__ == "__main__":
    unittest.main()
