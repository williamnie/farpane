import json
from pathlib import Path
import subprocess
import unittest


class ViewerImagePasteboardOwnerExplicitEnablementAuditTests(unittest.TestCase):
    def test_viewer_image_owner_is_single_bounded_and_explicit(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-viewer-image-pasteboard-owner-explicit-enablement.py",
            ],
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            completed.returncode,
            0,
            completed.stderr or completed.stdout,
        )
        document = json.loads(completed.stdout)
        self.assertEqual(
            document["schema"],
            "farpane-viewer-image-pasteboard-owner-explicit-enablement-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "viewer-image-pasteboard-owner-explicitly-enabled",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))

        claims = document["claims"]
        self.assertTrue(claims["viewerImageDirectionsExplicitlyEnabled"])
        self.assertTrue(claims["oneAppKitOwnerHandlesTextRichAndImageClipboard"])
        self.assertFalse(claims["preSessionClipboardUploaded"])
        self.assertFalse(claims["invalidImageFallsBackToTextOrRich"])
        self.assertTrue(claims["localTIFFCanonicalizedToPNG"])
        self.assertFalse(claims["clipboardContentLogged"])
        self.assertFalse(claims["hostProductImageClipboardEnabled"])
        self.assertFalse(claims["svgRenderingSanitized"])
        self.assertFalse(claims["filePromiseClipboardEnabled"])

        remaining = document["remainingBoundary"]
        self.assertFalse(remaining["viewerImagePasteboardOwnerRequired"])
        self.assertTrue(remaining["hostImageExplicitOptInRequired"])
        self.assertTrue(
            remaining["installedTwoMacImageClipboardAcceptanceRequired"]
        )
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-image-bootstrap-home-opt-in-contract",
        )


if __name__ == "__main__":
    unittest.main()
