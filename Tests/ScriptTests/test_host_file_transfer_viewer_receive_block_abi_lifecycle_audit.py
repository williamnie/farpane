import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferViewerReceiveBlockABILifecycleAuditTests(unittest.TestCase):
    def test_callback_is_scoped_exact_bounded_and_product_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-viewer-receive-block-abi-lifecycle.py",
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
            "farpane-host-file-transfer-viewer-receive-block-abi-lifecycle-audit",
        )
        self.assertEqual(
            document["status"],
            "viewer-receive-block-abi-lifecycle-implemented-product-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["viewerReceiveBlockABILifecycleImplemented"])
        self.assertFalse(claims["viewerIOLoopReceiveInterceptionImplemented"])
        self.assertFalse(claims["viewerDownloadWireDispatchImplemented"])
        self.assertFalse(claims["viewerDestinationWriteImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-viewer-io-loop-receive-interception-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
