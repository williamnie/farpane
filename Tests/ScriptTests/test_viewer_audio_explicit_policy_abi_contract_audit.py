import json
from pathlib import Path
import subprocess
import unittest


class ViewerAudioExplicitPolicyABIContractAuditTests(unittest.TestCase):
    def test_viewer_audio_is_abi_capable_and_product_default_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-viewer-audio-explicit-policy-abi-contract.py",
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
            "farpane-viewer-audio-explicit-policy-abi-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "viewer-audio-abi-capable-product-default-off",
        )
        self.assertEqual(document["currentABI"], {"host": 19, "viewer": 18})
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["viewerReceiveAudioABICapable"])
        self.assertFalse(claims["viewerAudioEnabledByDefault"])
        self.assertTrue(claims["viewerAudioProductEnabled"])
        self.assertTrue(claims["dedicatedFileSessionRejectsAudio"])
        self.assertTrue(claims["viewerRemoteAudioPermissionPresented"])
        self.assertTrue(claims["virtualAudioInputSelectionImplemented"])
        self.assertFalse(claims["installedAudioAcceptanceComplete"])
        self.assertFalse(claims["rustDeskWireChanged"])
        self.assertFalse(claims["hermesChanged"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-audio-product-development-completion-audit",
        )


if __name__ == "__main__":
    unittest.main()
