import json
from pathlib import Path
import subprocess
import unittest


class HostModeDevelopmentCompletionAuditTests(unittest.TestCase):
    def test_h0_through_h6_development_is_complete_without_claiming_release(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-mode-development-completion.py"],
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(
            completed.returncode,
            0,
            completed.stderr or completed.stdout,
        )
        document = json.loads(completed.stdout)
        self.assertEqual(
            document["schema"],
            "farpane-host-mode-development-completion-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "development-complete-acceptance-pending",
        )
        self.assertEqual(
            document["currentABI"],
            {"viewer": 18, "host": 19, "hostMedia": 1},
        )
        self.assertEqual(len(document["requiredAudits"]), 18)
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertEqual(document["remainingDevelopmentGaps"], [])
        claims = document["claims"]
        for phase in range(7):
            self.assertTrue(claims[f"h{phase}DevelopmentComplete"])
        self.assertTrue(claims["hostModeDevelopmentComplete"])
        self.assertFalse(claims["installedCurrentBuildSingleMacSmokeComplete"])
        self.assertFalse(claims["dualMacAcceptanceComplete"])
        self.assertFalse(claims["performanceAcceptanceComplete"])
        self.assertFalse(claims["notarizedCleanMachineAcceptanceComplete"])
        self.assertFalse(claims["releaseAcceptanceComplete"])
        self.assertIsNone(document["nextImplementationBoundary"])


if __name__ == "__main__":
    unittest.main()
