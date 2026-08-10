import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferViewerSafeReceiveCommitLifecycleAuditTests(unittest.TestCase):
    def test_commit_is_durable_atomic_no_replace_and_product_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-viewer-safe-receive-commit-lifecycle.py",
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
            "farpane-host-file-transfer-viewer-safe-receive-commit-lifecycle-audit",
        )
        self.assertEqual(
            document["status"],
            "viewer-safe-receive-commit-lifecycle-implemented-product-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["viewerPayloadWriteImplemented"])
        self.assertTrue(claims["viewerFinalCommitImplemented"])
        self.assertFalse(claims["viewerDownloadWireDispatchImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-viewer-download-dispatch-receive-adapter-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
