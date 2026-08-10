import json
from pathlib import Path
import subprocess
import unittest


class ViewerPasteboardOwnerExplicitEnablementAuditTests(unittest.TestCase):
    def test_viewer_product_owner_is_bounded_and_explicit(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-viewer-pasteboard-owner-explicit-enablement.py",
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
            "farpane-viewer-pasteboard-owner-explicit-enablement-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "viewer-pasteboard-owner-explicitly-enabled",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(document["claims"]["viewerDirectionsExplicitlyEnabled"])
        self.assertTrue(document["claims"]["appKitOwnsViewerPasteboard"])
        self.assertFalse(document["claims"]["preSessionClipboardUploaded"])
        self.assertTrue(document["claims"]["pollingBackoffBounded"])
        self.assertFalse(document["claims"]["clipboardContentLogged"])
        self.assertFalse(document["claims"]["hostClipboardEnabled"])
        self.assertFalse(document["claims"]["endToEndClipboardEnabled"])
        self.assertFalse(document["claims"]["richClipboardEnabled"])
        self.assertTrue(all(document["remainingBoundary"].values()))
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-small-text-clipboard-explicit-opt-in-contract",
        )


if __name__ == "__main__":
    unittest.main()
