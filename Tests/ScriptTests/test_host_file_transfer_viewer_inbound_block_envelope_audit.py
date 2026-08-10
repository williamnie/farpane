import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferViewerInboundBlockEnvelopeAuditTests(unittest.TestCase):
    def test_block_is_owned_bounded_exact_and_product_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-viewer-inbound-block-envelope.py",
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
            "farpane-host-file-transfer-viewer-inbound-block-envelope-audit",
        )
        self.assertEqual(
            document["status"],
            "viewer-inbound-block-envelope-implemented-product-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["viewerInboundBlockEnvelopeImplemented"])
        self.assertFalse(claims["viewerReceiveBlockABIImplemented"])
        self.assertFalse(claims["viewerDownloadWireDispatchImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-viewer-receive-block-abi-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
