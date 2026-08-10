import json
from pathlib import Path
import subprocess
import unittest


class HostViewerImageTransferWiringContractAuditTests(unittest.TestCase):
    def test_host_viewer_image_transport_is_bounded_and_default_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-viewer-image-transfer-wiring-contract.py"],
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
            "farpane-host-viewer-image-transfer-wiring-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "host-viewer-image-transfer-wired-viewer-enabled",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(document["claims"]["hostABIv15Implemented"])
        self.assertTrue(document["claims"]["imageDirectionsDefaultOff"])
        self.assertTrue(document["claims"]["imageTransportCanonicalAndBounded"])
        self.assertTrue(
            document["claims"]["sessionRevocationAppliesBeforeImageParsing"]
        )
        self.assertTrue(document["claims"]["viewerProductImageClipboardEnabled"])
        self.assertFalse(document["claims"]["hostProductImageClipboardEnabled"])
        self.assertFalse(document["claims"]["svgRenderingSanitized"])
        self.assertFalse(
            document["remainingBoundary"]["hostViewerImageTransportWiringRequired"]
        )
        self.assertFalse(
            document["remainingBoundary"]["singlePasteboardOwnerImageIntegrationRequired"]
        )
        self.assertTrue(
            document["remainingBoundary"]["hostImageExplicitOptInRequired"]
        )
        self.assertTrue(
            document["remainingBoundary"]["installedTwoMacImageClipboardAcceptanceRequired"]
        )
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-image-bootstrap-home-opt-in-contract",
        )


if __name__ == "__main__":
    unittest.main()
