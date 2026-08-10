import json
from pathlib import Path
import subprocess
import unittest


class HostClipboardPolicyContractAuditTests(unittest.TestCase):
    def test_read_write_policy_is_independent_but_data_path_stays_closed(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-clipboard-policy-contract.py"],
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
            "farpane-host-clipboard-policy-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "clipboard-read-write-policy-contract",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(document["claims"]["readWritePolicyRepresentable"])
        self.assertFalse(document["claims"]["clipboardDataPathEnabled"])
        self.assertTrue(document["claims"]["boundedSmallTextImplemented"])
        self.assertFalse(document["claims"]["richClipboardImplemented"])
        self.assertFalse(
            document["remainingBoundary"]["independentRevocationCommandsRequired"]
        )
        self.assertFalse(document["remainingBoundary"]["directionalXPCUIRequired"])
        self.assertFalse(
            document["remainingBoundary"]["eventDrivenDynamicBackoffRequired"]
        )
        self.assertFalse(
            document["remainingBoundary"]["temporaryObjectCleanupRequired"]
        )
        self.assertTrue(all(
            value for name, value in document["remainingBoundary"].items()
            if name not in {
                "independentRevocationCommandsRequired",
                "directionalXPCUIRequired",
                "eventDrivenDynamicBackoffRequired",
                "temporaryObjectCleanupRequired",
            }
        ))
        self.assertEqual(
            document["nextImplementationBoundary"],
            "viewer-small-text-clipboard-api-contract",
        )


if __name__ == "__main__":
    unittest.main()
