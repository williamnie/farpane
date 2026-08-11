import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferViewerUploadSelectionManifestContractAuditTests(
    unittest.TestCase
):
    def test_current_repository_passes(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-viewer-upload-selection-manifest-contract.py",
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
            "viewer-upload-selection-manifest-implemented-product-on",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        claims = document["claims"]
        self.assertTrue(claims["viewerUploadSelectionImplemented"])
        self.assertTrue(claims["descriptorOwnedManifestImplemented"])
        self.assertTrue(claims["pathFreeUploadRequestImplemented"])
        self.assertTrue(claims["viewerABIV14SemanticReadAvailable"])
        self.assertTrue(claims["viewerUploadWireDispatchImplemented"])
        self.assertTrue(claims["viewerUploadProductActionImplemented"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-viewer-upload-wire-abi-ownership-audit",
        )


if __name__ == "__main__":
    unittest.main()
