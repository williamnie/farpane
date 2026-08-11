import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferProductDevelopmentCompletionAuditTests(
    unittest.TestCase
):
    def test_current_repository_reports_product_development_complete(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-product-development-completion.py",
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
            document["status"],
            "product-development-complete",
        )
        self.assertEqual(document["failedRequiredAudits"], [])
        self.assertGreaterEqual(document["requiredAuditCount"], 40)
        self.assertTrue(all(document["evidence"].values()))
        claims = document["claims"]
        self.assertTrue(claims["hostExplicitReceiveOptInImplemented"])
        self.assertTrue(claims["hostReceiveDataPlaneImplemented"])
        self.assertTrue(claims["hostSendDataPlaneImplemented"])
        self.assertTrue(claims["viewerDownloadProductActionImplemented"])
        self.assertTrue(claims["viewerUploadSelectionManifestImplemented"])
        self.assertTrue(claims["viewerUploadProductActionImplemented"])
        self.assertTrue(claims["fileTransferProductDevelopmentComplete"])
        self.assertFalse(claims["installedSingleMacSmokeComplete"])
        self.assertFalse(claims["twoMacBidirectionalAcceptanceComplete"])
        self.assertEqual(
            document["remainingDevelopmentGaps"],
            [],
        )
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-installed-single-mac-smoke",
        )


if __name__ == "__main__":
    unittest.main()
