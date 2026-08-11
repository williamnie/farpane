import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferViewerProductCompositionLifecycleAuditTests(unittest.TestCase):
    def test_product_composition_is_dedicated_owned_and_entry_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-viewer-product-composition-lifecycle.py",
            ],
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        document = json.loads(completed.stdout)
        self.assertEqual(
            document["schema"],
            "farpane-host-file-transfer-viewer-product-composition-lifecycle-audit",
        )
        self.assertEqual(
            document["status"],
            "viewer-product-composition-implemented-entry-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["viewerSessionOrchestrationImplemented"])
        self.assertTrue(claims["viewerProductCompositionImplemented"])
        self.assertFalse(claims["viewerDownloadPickerActionImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-viewer-download-picker-action-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
