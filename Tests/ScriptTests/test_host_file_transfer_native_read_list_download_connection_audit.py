import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferNativeReadListDownloadConnectionAuditTests(unittest.TestCase):
    def test_native_read_list_download_connection_is_bounded_and_product_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-native-read-list-download-connection.py",
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
            "farpane-host-file-transfer-native-read-list-download-connection-audit",
        )
        self.assertEqual(
            document["status"],
            "native-read-list-download-connection-implemented-product-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["nativeReadListSnapshotPrimitiveImplemented"])
        self.assertTrue(
            claims["nativeReadListDownloadConnectionLifecycleImplemented"]
        )
        self.assertTrue(claims["viewerDestinationProgressContractImplemented"])
        self.assertTrue(claims["viewerCoreFileTransferABISeamImplemented"])
        self.assertFalse(claims["viewerCoreFileTransferRuntimeImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-viewer-core-event-command-runtime-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
