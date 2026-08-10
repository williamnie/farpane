import json
from pathlib import Path
import subprocess
import unittest


class ViewerClipboardImageAPIContractAuditTests(unittest.TestCase):
    def test_viewer_image_api_is_bounded_directional_and_default_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-viewer-clipboard-image-api-contract.py"],
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
            "farpane-viewer-image-clipboard-api-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "viewer-image-clipboard-api-default-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(document["claims"]["viewerABIv8Implemented"])
        self.assertTrue(document["claims"]["imageDirectionsDefaultOff"])
        self.assertTrue(document["claims"]["rgbaAndPNGBoundedTo128MiB"])
        self.assertTrue(document["claims"]["svgBoundedTo4MiB"])
        self.assertFalse(document["claims"]["disabledReceiveParsesImagePayload"])
        self.assertTrue(document["claims"]["swiftCopiesCallbackScopedBytes"])
        self.assertFalse(document["claims"]["viewerProductImageClipboardEnabled"])
        self.assertFalse(document["claims"]["hostImageClipboardTransportCapable"])
        self.assertFalse(document["claims"]["svgRenderingSanitized"])
        self.assertTrue(
            document["remainingBoundary"]["hostViewerImageTransportWiringRequired"]
        )
        self.assertTrue(
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
            "host-viewer-image-transfer-wiring-contract",
        )


if __name__ == "__main__":
    unittest.main()
