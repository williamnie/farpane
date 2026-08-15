import json
from pathlib import Path
import subprocess
import unittest


class HostAudioBootstrapVirtualInputSelectionContractAuditTests(unittest.TestCase):
    def test_schema_catalog_home_and_runtime_are_one_fail_closed_policy(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-audio-bootstrap-virtual-input-selection-contract.py",
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
            "farpane-host-audio-bootstrap-virtual-input-selection-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "host-audio-bootstrap-and-virtual-input-selection-implemented",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(
            document["claims"]["nativeSystemAudioIsDefaultSource"]
        )
        self.assertFalse(document["claims"]["virtualInputAutoInstalled"])
        self.assertTrue(document["claims"]["missingExplicitInputFallsClosed"])
        self.assertFalse(document["claims"]["dualMacAudioAcceptanceComplete"])
        self.assertFalse(document["claims"]["hermesChanged"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-audio-product-development-completion-audit",
        )


if __name__ == "__main__":
    unittest.main()
