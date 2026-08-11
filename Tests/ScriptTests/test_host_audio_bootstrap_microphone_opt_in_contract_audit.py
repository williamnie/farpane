import json
from pathlib import Path
import subprocess
import unittest


class HostAudioBootstrapMicrophoneOptInContractAuditTests(unittest.TestCase):
    def test_audio_opt_in_requires_main_app_tcc_and_both_host_owners(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-audio-bootstrap-microphone-opt-in-contract.py",
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
            "farpane-host-audio-bootstrap-microphone-opt-in-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "host-audio-bootstrap-microphone-opt-in-ready",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertFalse(claims["hostAudioEnabledByDefault"])
        self.assertTrue(claims["explicitHomeMicrophoneOptInImplemented"])
        self.assertTrue(claims["mainAppOwnsPromptingAuthorization"])
        self.assertTrue(claims["hostAgentNeverPromptsForMicrophone"])
        self.assertTrue(claims["backgroundHostProjectionImplemented"])
        self.assertTrue(claims["legacyHostProjectionImplemented"])
        self.assertFalse(claims["viewerAudioImplemented"])
        self.assertFalse(claims["virtualAudioInputSelectionImplemented"])
        self.assertFalse(claims["installedAudioAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "viewer-audio-explicit-policy-abi-contract",
        )


if __name__ == "__main__":
    unittest.main()
