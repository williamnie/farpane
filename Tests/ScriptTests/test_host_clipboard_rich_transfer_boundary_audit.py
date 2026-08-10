import json
from pathlib import Path
import subprocess
import unittest


class HostClipboardRichTransferBoundaryAuditTests(unittest.TestCase):
    def test_rich_types_are_classified_but_never_inline_admitted(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-clipboard-rich-transfer-boundary.py",
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
            "farpane-host-clipboard-rich-transfer-boundary-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "rich-payload-independent-transfer-boundary",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(document["claims"]["inlineSmallTextRemainsBounded"])
        self.assertFalse(document["claims"]["embeddedNULAccepted"])
        self.assertTrue(document["claims"]["richTypesClassified"])
        self.assertFalse(document["claims"]["richTypesAdmittedToInlinePath"])
        self.assertFalse(document["claims"]["specialUTIOrFormatAccepted"])
        self.assertTrue(document["claims"]["independentRichTransferImplemented"])
        self.assertFalse(document["remainingBoundary"]["boundedRichTransferEnvelopeRequired"])
        self.assertFalse(document["remainingBoundary"]["richViewerABIRequired"])
        self.assertTrue(document["remainingBoundary"]["richPasteboardOwnerRequired"])
        self.assertTrue(document["remainingBoundary"]["installedTwoMacAcceptanceRequired"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-rich-text-bootstrap-home-opt-in-contract",
        )


if __name__ == "__main__":
    unittest.main()
