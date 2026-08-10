import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferViewerDownloadStartABILifecycleAuditTests(unittest.TestCase):
    def test_start_is_exact_path_free_bounded_and_product_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-viewer-download-start-abi-lifecycle.py",
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
            "farpane-host-file-transfer-viewer-download-start-abi-lifecycle-audit",
        )
        self.assertEqual(
            document["status"],
            "viewer-download-start-abi-lifecycle-implemented-product-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["viewerRecursiveManifestABILifecycleImplemented"])
        self.assertTrue(claims["viewerDownloadStartImplemented"])
        self.assertFalse(claims["viewerDownloadWireDispatchImplemented"])
        self.assertFalse(claims["viewerDownloadIOImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-viewer-download-dispatch-progress-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
