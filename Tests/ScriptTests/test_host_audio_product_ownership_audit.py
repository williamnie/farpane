import json
from pathlib import Path
import subprocess
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]
AUDIT = REPOSITORY / "Scripts" / "audit-host-audio-product-ownership.py"


class HostAudioProductOwnershipAuditTests(unittest.TestCase):
    def test_h6_1_audio_ownership_and_next_abi_checkpoint_are_frozen(self) -> None:
        self.assertTrue(
            AUDIT.is_file(),
            "Scripts/audit-host-audio-product-ownership.py must exist",
        )
        completed = subprocess.run(
            ["python3", str(AUDIT)],
            cwd=REPOSITORY,
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
            "farpane-host-audio-product-ownership-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "product-selector-implemented-development-audit-pending",
        )
        self.assertEqual(document["currentABI"], {"host": 19, "viewer": 18})
        self.assertEqual(document["targetContract"]["hostABI"], 19)
        self.assertEqual(document["targetContract"]["viewerABI"], 18)
        self.assertEqual(
            document["targetContract"]["defaultCaptureSource"],
            "native ScreenCaptureKit system-audio loopback",
        )
        self.assertEqual(
            document["targetContract"]["systemAudioRoute"],
            "native by default; explicit CoreAudio input remains available",
        )
        self.assertTrue(all(document["evidence"].values()))
        self.assertEqual(document["gaps"], {})
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingGaps"], [])
        claims = document["claims"]
        self.assertFalse(claims["hostAudioEnabled"])
        self.assertTrue(claims["viewerAudioEnabled"])
        self.assertFalse(claims["audioProductDevelopmentComplete"])
        self.assertTrue(claims["virtualInputProductSelectorImplemented"])
        self.assertFalse(claims["hostABIChangeRequired"])
        self.assertFalse(claims["viewerABIChangeRequired"])
        self.assertFalse(claims["rustDeskWireChangeRequired"])
        self.assertFalse(claims["hermesChangeRequired"])
        self.assertFalse(claims["rootDependencyChangeRequired"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-audio-product-development-completion-audit",
        )


if __name__ == "__main__":
    unittest.main()
