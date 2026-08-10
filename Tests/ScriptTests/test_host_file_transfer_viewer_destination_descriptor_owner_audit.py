import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferViewerDestinationDescriptorOwnerAuditTests(unittest.TestCase):
    def test_owner_is_descriptor_pinned_session_bound_and_product_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-file-transfer-viewer-destination-descriptor-owner.py"],
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        document = json.loads(completed.stdout)
        self.assertEqual(
            document["schema"],
            "farpane-host-file-transfer-viewer-destination-descriptor-owner-audit",
        )
        self.assertEqual(
            document["status"],
            "viewer-destination-descriptor-owner-implemented-product-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["viewerDestinationDescriptorOwnerImplemented"])
        self.assertFalse(claims["viewerRecursiveManifestImplemented"])
        self.assertFalse(claims["viewerDownloadIOImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-viewer-recursive-manifest-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
