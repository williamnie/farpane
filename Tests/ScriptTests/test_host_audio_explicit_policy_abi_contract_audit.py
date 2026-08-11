import json
from pathlib import Path
import subprocess
import unittest


class HostAudioExplicitPolicyABIContractAuditTests(unittest.TestCase):
    def test_host_audio_is_abi_capable_but_product_default_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-audio-explicit-policy-abi-contract.py",
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
            "farpane-host-audio-explicit-policy-abi-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "host-audio-abi-capable-product-default-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        implementation = document["implementation"]
        self.assertEqual(implementation["hostABIVersion"], 19)
        self.assertTrue(all(implementation["evidence"].values()))
        self.assertTrue(all(implementation["sourceLines"].values()))
        claims = document["claims"]
        self.assertFalse(claims["hostAudioEnabledByDefault"])
        self.assertTrue(claims["hostAudioABICapable"])
        self.assertTrue(claims["hostAudioProductEnabled"])
        self.assertTrue(claims["viewerAudioImplemented"])
        self.assertTrue(claims["microphoneTCCImplemented"])
        self.assertFalse(claims["installedAudioAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-audio-product-development-completion-audit",
        )


if __name__ == "__main__":
    unittest.main()
