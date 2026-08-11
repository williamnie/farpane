import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferViewerUploadWireJobLifecycleAuditTests(unittest.TestCase):
    def test_current_repository_reports_wire_implemented_product_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-file-transfer-viewer-upload-wire-job-lifecycle.py"],
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr or completed.stdout)
        document = json.loads(completed.stdout)
        self.assertEqual(document["status"], "viewer-upload-wire-job-implemented-product-off")
        self.assertTrue(all(document["evidence"].values()))
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        claims = document["claims"]
        self.assertTrue(claims["viewerUploadWireImplemented"])
        self.assertTrue(claims["swiftRetainsSourceDescriptorOwnership"])
        self.assertFalse(claims["existingTargetReplacementImplemented"])
        self.assertFalse(claims["viewerUploadProductActionImplemented"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-viewer-upload-product-action-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
