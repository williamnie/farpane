import json
from pathlib import Path
import subprocess
import unittest


class ViewerClipboardRichTextAPIContractAuditTests(unittest.TestCase):
    def test_viewer_rich_text_api_is_bounded_directional_and_default_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-viewer-clipboard-rich-text-api-contract.py",
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
            "farpane-viewer-rich-text-clipboard-api-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "viewer-rich-text-clipboard-api-default-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(document["claims"]["viewerABIv7Implemented"])
        self.assertTrue(document["claims"]["richDirectionsDefaultOff"])
        self.assertTrue(document["claims"]["plainFallbackBoundedTo64KiB"])
        self.assertTrue(
            document["claims"]["rtfAndHTMLIndependentlyBoundedTo1MiB"]
        )
        self.assertFalse(document["claims"]["disabledReceiveParsesRichPayload"])
        self.assertTrue(document["claims"]["swiftCopiesCallbackScopedBytes"])
        self.assertTrue(document["claims"]["viewerProductRichClipboardEnabled"])
        self.assertTrue(document["claims"]["hostRichClipboardTransportCapable"])
        self.assertFalse(document["claims"]["imageOrFileClipboardEnabled"])
        self.assertFalse(document["remainingBoundary"]["hostViewerRichTransportWiringRequired"])
        self.assertFalse(document["remainingBoundary"]["singlePasteboardOwnerRichIntegrationRequired"])
        self.assertTrue(document["remainingBoundary"]["installedTwoMacRichClipboardAcceptanceRequired"])
        self.assertTrue(document["remainingBoundary"]["physicalLatencyAndIdleCPUAcceptanceRequired"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-rich-text-clipboard-installed-two-mac-acceptance",
        )


if __name__ == "__main__":
    unittest.main()
