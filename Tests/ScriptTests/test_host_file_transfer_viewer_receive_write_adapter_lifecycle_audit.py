import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferViewerReceiveWriteAdapterLifecycleAuditTests(unittest.TestCase):
    def test_receive_write_adapter_is_exact_durable_and_product_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-viewer-receive-write-adapter-lifecycle.py",
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
            "farpane-host-file-transfer-viewer-receive-write-adapter-lifecycle-audit",
        )
        self.assertEqual(
            document["status"],
            "viewer-receive-write-adapter-implemented-product-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["viewerDownloadWireRequestImplemented"])
        self.assertTrue(claims["viewerDigestConfirmationImplemented"])
        self.assertTrue(claims["viewerReceiveWriteAdapterImplemented"])
        self.assertFalse(claims["viewerSessionOrchestrationImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-viewer-session-orchestration-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
