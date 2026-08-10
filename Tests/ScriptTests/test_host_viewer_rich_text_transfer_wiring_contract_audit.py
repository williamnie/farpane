import json
from pathlib import Path
import subprocess
import unittest


class HostViewerRichTextTransferWiringContractAuditTests(unittest.TestCase):
    def test_host_viewer_rich_text_transport_is_bounded_and_default_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-viewer-rich-text-transfer-wiring-contract.py",
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
            "farpane-host-viewer-rich-text-transfer-wiring-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "host-viewer-rich-text-transfer-wired-default-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(document["claims"]["hostABIv14Implemented"])
        self.assertTrue(document["claims"]["smallAndRichDirectionsIndependent"])
        self.assertTrue(document["claims"]["richTransportCanonicalAndBounded"])
        self.assertTrue(document["claims"]["sessionRevocationAppliesToRich"])
        self.assertFalse(document["claims"]["hostProductRichClipboardEnabled"])
        self.assertTrue(document["claims"]["viewerProductRichClipboardEnabled"])
        self.assertFalse(document["claims"]["imageOrFileClipboardEnabled"])
        self.assertFalse(
            document["remainingBoundary"]["hostViewerRichTransportWiringRequired"]
        )
        self.assertFalse(
            document["remainingBoundary"]["singlePasteboardOwnerRichIntegrationRequired"]
        )
        self.assertTrue(
            document["remainingBoundary"]["installedTwoMacRichClipboardAcceptanceRequired"]
        )
        self.assertTrue(
            document["remainingBoundary"]["physicalLatencyAndIdleCPUAcceptanceRequired"]
        )
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-rich-text-bootstrap-home-opt-in-contract",
        )


if __name__ == "__main__":
    unittest.main()
