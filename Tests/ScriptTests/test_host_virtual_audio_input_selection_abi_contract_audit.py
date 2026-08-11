import json
from pathlib import Path
import subprocess
import unittest


class HostVirtualAudioInputSelectionABIContractAuditTests(unittest.TestCase):
    def test_explicit_input_is_immutable_bounded_and_fails_closed(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-virtual-audio-input-selection-abi-contract.py",
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
            "farpane-host-virtual-audio-input-selection-abi-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "host-virtual-audio-input-abi-capable-product-default-microphone",
        )
        self.assertEqual(document["currentABI"], {"host": 19, "viewer": 18})
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        claims = document["claims"]
        self.assertFalse(claims["virtualInputSelectedByDefault"])
        self.assertFalse(claims["virtualInputProductSelectorImplemented"])
        self.assertTrue(claims["missingExplicitInputFallsClosed"])
        self.assertFalse(claims["rustDeskWireChanged"])
        self.assertFalse(claims["hermesChanged"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-audio-bootstrap-virtual-input-selection-contract",
        )


if __name__ == "__main__":
    unittest.main()
