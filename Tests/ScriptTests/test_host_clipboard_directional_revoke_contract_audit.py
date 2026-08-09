import json
from pathlib import Path
import subprocess
import unittest


class HostClipboardDirectionalRevokeContractAuditTests(unittest.TestCase):
    def test_core_directions_are_independent_while_xpc_ui_remain_closed(self) -> None:
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
        self.assertFalse(document["claims"]["directionalXPCImplemented"])
        self.assertFalse(document["claims"]["directionalHomeControlsImplemented"])
        self.assertFalse(document["claims"]["clipboardEnabledByDefault"])
        self.assertTrue(all(document["remainingBoundary"].values()))
        self.assertEqual(
            document["nextImplementationBoundary"],
            "directional-revoke-xpc-ui-contract",
        )


if __name__ == "__main__":
    unittest.main()
