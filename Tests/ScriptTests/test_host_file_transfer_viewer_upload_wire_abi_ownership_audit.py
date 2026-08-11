import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferViewerUploadWireABIOwnershipAuditTests(
    unittest.TestCase
):
    def test_current_repository_freezes_minimal_path_free_seam(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-viewer-upload-wire-abi-ownership.py",
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
            "viewer-upload-wire-abi-ownership-frozen",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        claims = document["claims"]
        self.assertFalse(claims["upstreamPathBasedSendFilesReusable"])
        self.assertTrue(claims["canonicalRustDeskUploadWireReusable"])
        self.assertTrue(claims["nativeHostReceivePlaneReusable"])
        self.assertTrue(claims["swiftRetainsSourceDescriptorOwnership"])
        self.assertTrue(claims["rustOwnsUploadProtocolState"])
        self.assertTrue(claims["viewerABIV14Required"])
        self.assertFalse(claims["viewerABIChangedByThisAudit"])
        self.assertTrue(claims["viewerABIV14SemanticReadImplemented"])
        self.assertTrue(claims["viewerUploadWireImplemented"])
        seam = document["frozenSeam"]
        self.assertEqual(seam["maximumReadBytes"], 128 * 1024)
        self.assertFalse(seam["pathOrDescriptorCrossesABI"])
        self.assertFalse(seam["overwriteAllowed"])
        self.assertFalse(seam["resumeAllowed"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-viewer-upload-product-action-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
