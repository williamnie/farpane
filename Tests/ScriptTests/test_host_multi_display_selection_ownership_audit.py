import json
import subprocess
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
AUDIT = REPOSITORY / "Scripts" / "audit-host-multi-display-selection-ownership.py"


class HostMultiDisplaySelectionOwnershipAuditTests(unittest.TestCase):
    def test_h6_4_viewer_display_selection_checkpoint_is_frozen(self) -> None:
        self.assertTrue(
            AUDIT.is_file(),
            "Scripts/audit-host-multi-display-selection-ownership.py must exist",
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
            "farpane-host-multi-display-selection-ownership-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"], "catalog-abi-implemented-selection-pending"
        )
        self.assertEqual(document["currentABI"], {"host": 17, "viewer": 15})
        self.assertEqual(document["targetContract"]["viewerABI"], 15)
        self.assertEqual(document["targetContract"]["hostABI"], 17)
        self.assertEqual(
            document["targetContract"]["catalogIdentity"],
            "connectionEpoch + catalogRevision + displayIndex",
        )
        self.assertEqual(
            document["nextImplementationBoundary"],
            "viewer-select-display-command-lifecycle",
        )
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["gaps"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertFalse(document["claims"]["currentMultiDisplayProductComplete"])
        self.assertFalse(document["claims"]["hostABIChangeRequired"])
        self.assertFalse(document["claims"]["viewerABIChangeRequired"])
        self.assertTrue(document["claims"]["installedTwoMacAcceptanceStillRequired"])


if __name__ == "__main__":
    unittest.main()
