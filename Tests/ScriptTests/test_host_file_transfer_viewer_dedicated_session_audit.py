import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferViewerDedicatedSessionAuditTests(unittest.TestCase):
    def test_dedicated_session_and_cancel_are_gated_and_product_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-file-transfer-viewer-dedicated-session.py"],
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        document = json.loads(completed.stdout)
        self.assertEqual(
            document["schema"],
            "farpane-host-file-transfer-viewer-dedicated-session-audit",
        )
        self.assertEqual(
            document["status"],
            "viewer-dedicated-file-session-cancel-implemented-product-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["viewerDedicatedFileSessionImplemented"])
        self.assertTrue(claims["viewerCancelDispatchImplemented"])
        self.assertFalse(claims["viewerListManifestLifecycleImplemented"])
        self.assertFalse(claims["viewerDestinationIOImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-viewer-destination-descriptor-owner",
        )


if __name__ == "__main__":
    unittest.main()
