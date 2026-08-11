import json
from pathlib import Path
import subprocess
import unittest


class HostAudioProductDevelopmentCompletionAuditTests(unittest.TestCase):
    def test_h6_1_development_is_complete_without_claiming_acceptance(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-audio-product-development-completion.py",
            ],
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
            "farpane-host-audio-product-development-completion-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["status"], "product-development-complete")
        self.assertEqual(document["currentABI"], {"viewer": 18, "host": 19})
        self.assertEqual(len(document["requiredAudits"]), 7)
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertEqual(document["remainingDevelopmentGaps"], [])
        claims = document["claims"]
        self.assertTrue(claims["hostAudioProductImplemented"])
        self.assertTrue(claims["viewerAudioProductImplemented"])
        self.assertTrue(claims["virtualInputProductSelectorImplemented"])
        self.assertTrue(claims["audioProductDevelopmentComplete"])
        self.assertFalse(claims["installedCurrentBuildSingleMacSmokeComplete"])
        self.assertFalse(claims["dualMacAudioAcceptanceComplete"])
        self.assertFalse(claims["virtualAudioDeviceAutoInstalled"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-mode-development-completion-audit",
        )


if __name__ == "__main__":
    unittest.main()
