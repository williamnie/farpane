import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferViewerABIv9SeamAuditTests(unittest.TestCase):
    def test_viewer_file_transfer_abi_seam_is_default_off_and_fail_closed(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-file-transfer-viewer-abi-v9-seam.py"],
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
            "farpane-host-file-transfer-viewer-abi-v9-seam-audit",
        )
        self.assertEqual(
            document["status"],
            "viewer-file-transfer-abi-v9-seam-implemented-product-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["viewerFileTransferABISeamImplemented"])
        self.assertFalse(claims["viewerFileTransferRuntimeImplemented"])
        self.assertFalse(claims["viewerDestinationDescriptorOwnerImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-viewer-core-event-command-runtime-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
