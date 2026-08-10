import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferNativeResumeDigestLifecycleAuditTests(unittest.TestCase):
    def test_single_file_resume_is_verified_and_product_remains_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-native-resume-digest-lifecycle.py",
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
            "farpane-host-file-transfer-native-resume-digest-lifecycle-audit",
        )
        self.assertEqual(
            document["status"],
            "native-single-file-resume-digest-implemented-product-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["nativeNewFileWriteLifecycleImplemented"])
        self.assertTrue(claims["nativeSingleFileResumeDigestLifecycleImplemented"])
        self.assertFalse(claims["nativeMultiFileResumeImplemented"])
        self.assertFalse(claims["nativeExistingTargetDecisionImplemented"])
        self.assertFalse(claims["nativeReadListDownloadImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-native-existing-target-decision-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
