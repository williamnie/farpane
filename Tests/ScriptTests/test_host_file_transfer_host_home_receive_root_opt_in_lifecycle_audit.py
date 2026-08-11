import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferHostHomeReceiveRootOptInLifecycleAuditTests(
    unittest.TestCase
):
    def test_current_repository_passes(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-host-home-receive-root-opt-in-lifecycle.py",
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
            "host-home-receive-root-opt-in-implemented",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        claims = document["claims"]
        self.assertFalse(claims["hostFileTransferEnabledByDefault"])
        self.assertTrue(claims["explicitHomeOptInImplemented"])
        self.assertTrue(claims["privateReceiveRootProvisioningImplemented"])
        self.assertTrue(claims["backgroundHostProjectionImplemented"])
        self.assertTrue(claims["legacyHostProjectionImplemented"])
        self.assertFalse(claims["installedSingleMacSmokeComplete"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-product-development-completion-audit",
        )


if __name__ == "__main__":
    unittest.main()
