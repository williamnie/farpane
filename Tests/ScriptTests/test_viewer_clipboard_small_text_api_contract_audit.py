import json
from pathlib import Path
import subprocess
import unittest


class ViewerClipboardSmallTextAPIContractAuditTests(unittest.TestCase):
    def test_viewer_small_text_api_is_bounded_directional_and_default_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-viewer-clipboard-small-text-api-contract.py",
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
            "farpane-viewer-small-text-clipboard-api-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "viewer-small-text-clipboard-api-default-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(document["claims"]["viewerABIv7RetainsSmallText"])
        self.assertTrue(document["claims"]["directionsIndependentlyEnforced"])
        self.assertTrue(document["claims"]["smallTextBoundedTo64KiB"])
        self.assertFalse(document["claims"]["viewerRustOwnsSystemPasteboard"])
        self.assertTrue(document["claims"]["viewerProductClipboardEnabled"])
        self.assertFalse(
            document["claims"]["hostProductClipboardEnabledByDefault"]
        )
        self.assertTrue(document["claims"]["hostProductExplicitOptInCapable"])
        self.assertTrue(
            document["claims"]["endToEndSmallTextExplicitOptInCapable"]
        )
        self.assertFalse(document["claims"]["richClipboardEnabled"])
        self.assertFalse(
            document["remainingBoundary"]["viewerPasteboardOwnerRequired"]
        )
        self.assertFalse(
            document["remainingBoundary"]["viewerExplicitEnablementRequired"]
        )
        self.assertFalse(
            document["remainingBoundary"]["hostSmallTextExplicitOptInRequired"]
        )
        self.assertFalse(document["remainingBoundary"]["richPayloadTransferRequired"])
        self.assertTrue(document["remainingBoundary"]["physicalOwnershipAndTeardownAcceptanceRequired"])
        self.assertTrue(document["remainingBoundary"]["physicalLatencyAndIdleCPUAcceptanceRequired"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "viewer-rich-text-pasteboard-owner-explicit-enablement-contract",
        )


if __name__ == "__main__":
    unittest.main()
