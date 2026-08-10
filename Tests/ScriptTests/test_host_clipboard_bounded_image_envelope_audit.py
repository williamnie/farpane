import json
from pathlib import Path
import subprocess
import unittest


class HostClipboardBoundedImageEnvelopeAuditTests(unittest.TestCase):
    def test_image_envelope_is_owned_bounded_and_not_admitted(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-clipboard-bounded-image-envelope.py",
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
            "farpane-host-clipboard-bounded-image-envelope-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["status"], "bounded-image-envelope-contract")
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(document["claims"]["imageEnvelopeBounded"])
        self.assertTrue(document["claims"]["imageEnvelopeOwned"])
        self.assertTrue(document["claims"]["imageNetworkTransportEnabled"])
        self.assertTrue(document["claims"]["imagePasteboardEnabled"])
        self.assertTrue(document["claims"]["viewerImageProductEnabled"])
        self.assertFalse(document["claims"]["hostImageProductEnabled"])
        self.assertFalse(document["claims"]["svgSanitizedForRendering"])
        self.assertFalse(document["remainingBoundary"]["viewerImageABIRequired"])
        self.assertFalse(
            document["remainingBoundary"]["hostViewerImageTransportRequired"]
        )
        self.assertFalse(document["remainingBoundary"]["pasteboardOwnerRequired"])
        self.assertTrue(
            document["remainingBoundary"]["explicitHostProductOptInRequired"]
        )
        self.assertTrue(
            document["remainingBoundary"]["installedTwoMacAcceptanceRequired"]
        )
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-image-bootstrap-home-opt-in-contract",
        )


if __name__ == "__main__":
    unittest.main()
