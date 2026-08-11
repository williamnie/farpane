import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferBootstrapPublicationPolicyLifecycleAuditTests(
    unittest.TestCase
):
    def test_current_repository_passes(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-bootstrap-publication-policy-lifecycle.py",
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
            "bootstrap-publication-runtime-policy-implemented-home-opt-in-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(document["claims"]["bootstrapPolicyPublicationImplemented"])
        self.assertTrue(document["claims"]["agentRuntimePolicyProjectionImplemented"])
        self.assertFalse(document["claims"]["hostHomeFileTransferOptInImplemented"])
        self.assertFalse(document["claims"]["productFileTransferEnabledByDefault"])
        self.assertFalse(document["claims"]["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-host-home-receive-root-opt-in-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
