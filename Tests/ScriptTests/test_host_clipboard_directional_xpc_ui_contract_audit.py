import json
from pathlib import Path
import subprocess
import unittest


class HostClipboardDirectionalXPCUIContractAuditTests(unittest.TestCase):
    def test_xpc_and_home_keep_clipboard_directions_independent(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-clipboard-directional-xpc-ui-contract.py",
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
            "farpane-host-clipboard-directional-xpc-ui-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "directional-revoke-xpc-home-contract",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(document["claims"]["commandSchemaTwoImplemented"])
        self.assertTrue(document["claims"]["directionalXPCImplemented"])
        self.assertTrue(document["claims"]["directionalHomeControlsImplemented"])
        self.assertTrue(document["claims"]["legacyBidirectionalAliasPreserved"])
        self.assertFalse(document["claims"]["clipboardEnabledByDefault"])
        self.assertTrue(all(document["remainingBoundary"].values()))
        self.assertEqual(
            document["nextImplementationBoundary"],
            "event-first-dynamic-backoff-contract",
        )


if __name__ == "__main__":
    unittest.main()
