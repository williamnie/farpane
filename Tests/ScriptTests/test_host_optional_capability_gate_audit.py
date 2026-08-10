import json
from pathlib import Path
import subprocess
import unittest


class HostOptionalCapabilityGateAuditTests(unittest.TestCase):
    def test_optional_data_capabilities_default_off_before_h6(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-optional-capability-gate.py"],
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
            "farpane-host-optional-capability-gate-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "optional-data-capabilities-default-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertFalse(document["claims"]["clipboardEnabledByDefault"])
        self.assertTrue(document["claims"]["clipboardExplicitOptInCapable"])
        self.assertFalse(document["claims"]["richClipboardImplemented"])
        self.assertFalse(document["claims"]["fileTransferEnabled"])
        self.assertFalse(document["claims"]["systemAudioEnabled"])
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
        self.assertFalse(
            document["remainingBoundary"]["viewerSmallTextClipboardAPIRequired"]
        )
        self.assertFalse(
            document["remainingBoundary"]["explicitProductEnablementRequired"]
        )
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-small-text-clipboard-installed-two-mac-acceptance",
        )


if __name__ == "__main__":
    unittest.main()
