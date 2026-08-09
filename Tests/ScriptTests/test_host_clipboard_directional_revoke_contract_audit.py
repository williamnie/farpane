import json
from pathlib import Path
import subprocess
import unittest


class HostClipboardDirectionalRevokeContractAuditTests(unittest.TestCase):
    def test_core_and_xpc_ui_directions_are_independent(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-clipboard-directional-revoke-contract.py",
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
            document["schema"],
            "farpane-host-clipboard-directional-revoke-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "independent-directional-revoke-core-contract",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(document["claims"]["hostCoreDirectionalRevokeImplemented"])
        self.assertTrue(document["claims"]["swiftDirectDirectionalAPIImplemented"])
        self.assertTrue(document["claims"]["legacyBidirectionalAliasPreserved"])
        self.assertTrue(document["claims"]["directionalXPCImplemented"])
        self.assertTrue(document["claims"]["directionalHomeControlsImplemented"])
        self.assertFalse(document["claims"]["clipboardEnabledByDefault"])
        self.assertFalse(
            document["remainingBoundary"]["directionalXPCUIRequired"]
        )
        self.assertFalse(
            document["remainingBoundary"]["eventDrivenDynamicBackoffRequired"]
        )
        self.assertTrue(all(
            value for name, value in document["remainingBoundary"].items()
            if name not in {
                "directionalXPCUIRequired",
                "eventDrivenDynamicBackoffRequired",
            }
        ))
        self.assertEqual(
            document["nextImplementationBoundary"],
            "temporary-clipboard-object-cleanup-contract",
        )


if __name__ == "__main__":
    unittest.main()
