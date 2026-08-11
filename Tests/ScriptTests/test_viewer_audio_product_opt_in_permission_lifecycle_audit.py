import json
import subprocess
import unittest
from pathlib import Path


class ViewerAudioProductOptInPermissionLifecycleAuditTests(unittest.TestCase):
    def test_product_opt_in_and_remote_permission_lifecycle_are_complete(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            [
                "python3",
                str(
                    repository
                    / "Scripts/audit-viewer-audio-product-opt-in-permission-lifecycle.py"
                ),
            ],
            cwd=repository,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload["status"],
            "viewer-audio-product-opt-in-permission-lifecycle-ready",
        )
        self.assertEqual(payload["currentABI"], {"viewer": 18, "host": 19})
        self.assertTrue(payload["claims"]["nextConnectionOptInIsEphemeral"])
        self.assertTrue(payload["claims"]["remotePermissionIsConnectionScoped"])
        self.assertTrue(payload["claims"]["revocationClosesRustPlaybackGate"])
        self.assertFalse(payload["claims"]["viewerAudioEnabledByDefault"])
        self.assertTrue(payload["claims"]["virtualAudioInputSelectionImplemented"])
        self.assertFalse(payload["claims"]["installedAudioAcceptanceComplete"])
        self.assertEqual(
            payload["nextImplementationBoundary"],
            "host-audio-product-development-completion-audit",
        )
        self.assertEqual(payload["missingEvidence"], [])
        self.assertEqual(payload["missingSourceLines"], [])


if __name__ == "__main__":
    unittest.main()
