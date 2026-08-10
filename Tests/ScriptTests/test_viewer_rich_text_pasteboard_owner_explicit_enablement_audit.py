import json
from pathlib import Path
import subprocess
import unittest


class ViewerRichTextPasteboardOwnerExplicitEnablementAuditTests(unittest.TestCase):
    def test_viewer_rich_pasteboard_owner_is_single_bounded_and_explicit(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-viewer-rich-text-pasteboard-owner-explicit-enablement.py",
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
            "farpane-viewer-rich-text-pasteboard-owner-explicit-enablement-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "viewer-rich-text-pasteboard-owner-explicitly-enabled",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(document["claims"]["viewerRichDirectionsExplicitlyEnabled"])
        self.assertTrue(document["claims"]["oneAppKitOwnerHandlesSmallAndRichClipboard"])
        self.assertFalse(document["claims"]["preSessionClipboardUploaded"])
        self.assertTrue(document["claims"]["richBundlePreferredWithoutDuplicatePlainSend"])
        self.assertTrue(document["claims"]["pollingBackoffBounded"])
        self.assertFalse(document["claims"]["clipboardContentLogged"])
        self.assertTrue(document["claims"]["hostProductRichClipboardEnabled"])
        self.assertFalse(document["claims"]["imageOrFileClipboardEnabled"])
        self.assertFalse(
            document["remainingBoundary"]["viewerRichPasteboardOwnerRequired"]
        )
        self.assertFalse(document["remainingBoundary"]["hostRichProductOptInRequired"])
        self.assertTrue(
            document["remainingBoundary"]["installedTwoMacRichClipboardAcceptanceRequired"]
        )
        self.assertTrue(
            document["remainingBoundary"]["physicalLatencyAndIdleCPUAcceptanceRequired"]
        )
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-rich-text-clipboard-installed-two-mac-acceptance",
        )


if __name__ == "__main__":
    unittest.main()
