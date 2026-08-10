import json
from pathlib import Path
import subprocess
import unittest


class HostClipboardBoundedRichTextEnvelopeAuditTests(unittest.TestCase):
    def test_rich_text_envelope_is_owned_bounded_and_not_admitted(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-clipboard-bounded-rich-text-envelope.py",
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
            "farpane-host-clipboard-bounded-rich-text-envelope-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["status"], "bounded-rich-text-envelope-contract")
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(document["claims"]["richTextEnvelopeBounded"])
        self.assertTrue(document["claims"]["richTextEnvelopeOwned"])
        self.assertFalse(document["claims"]["richTextInlineAdmitted"])
        self.assertTrue(document["claims"]["richTextNetworkTransportEnabled"])
        self.assertTrue(document["claims"]["richTextPasteboardEnabled"])
        self.assertFalse(document["claims"]["imagesIncluded"])
        self.assertFalse(document["remainingBoundary"]["viewerRichTextABIRequired"])
        self.assertFalse(document["remainingBoundary"]["hostViewerTransportWiringRequired"])
        self.assertFalse(document["remainingBoundary"]["pasteboardOwnerRequired"])
        self.assertTrue(document["remainingBoundary"]["imagesRequired"])
        self.assertTrue(document["remainingBoundary"]["installedTwoMacAcceptanceRequired"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-rich-text-bootstrap-home-opt-in-contract",
        )


if __name__ == "__main__":
    unittest.main()
