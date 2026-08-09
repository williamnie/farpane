import json
import subprocess
import unittest
from pathlib import Path


class HostDisplayReconfigureContractAuditTests(unittest.TestCase):
    def test_pinned_display_reconfigure_ownership_is_frozen(self):
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-display-reconfigure-contract.py",
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
            "farpane-host-display-reconfigure-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["status"], "ownership-frozen")
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(
            document["authoritativeOwner"],
            "pinned RustDesk monitor video service",
        )
        self.assertEqual(
            document["displayIdentity"],
            "RustDesk display index, not CGDirectDisplayID",
        )
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(all(document["remainingBoundary"].values()))


if __name__ == "__main__":
    unittest.main()
