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
        self.assertTrue(document["claims"]["viewerABIv6Implemented"])
        self.assertTrue(document["claims"]["directionsIndependentlyEnforced"])
        self.assertTrue(document["claims"]["smallTextBoundedTo64KiB"])
        self.assertFalse(document["claims"]["viewerRustOwnsSystemPasteboard"])
        self.assertFalse(document["claims"]["productClipboardEnabled"])
        self.assertFalse(document["claims"]["richClipboardEnabled"])
        self.assertTrue(all(document["remainingBoundary"].values()))
        self.assertEqual(
            document["nextImplementationBoundary"],
            "viewer-pasteboard-owner-and-explicit-enablement-contract",
        )


if __name__ == "__main__":
    unittest.main()
