import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferNativeNewWriteLifecycleAuditTests(unittest.TestCase):
    def test_new_file_write_lifecycle_is_native_bounded_and_product_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-native-new-write-lifecycle.py",
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
            "farpane-host-file-transfer-native-new-write-lifecycle-audit",
        )
        self.assertEqual(
            document["status"],
            "native-new-file-write-lifecycle-implemented-product-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["nativeNewFileWriteLifecycleImplemented"])
        self.assertFalse(claims["nativeResumeDigestLifecycleImplemented"])
        self.assertFalse(claims["nativeOverwriteImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-native-resume-digest-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
