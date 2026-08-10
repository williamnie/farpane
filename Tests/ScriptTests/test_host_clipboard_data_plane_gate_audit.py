import json
import subprocess
import unittest


class HostClipboardDataPlaneGateAuditTests(unittest.TestCase):
    def test_audit_reports_complete_directional_small_text_gate(self) -> None:
        result = subprocess.run(
            ["python3", "Scripts/audit-host-clipboard-data-plane-gate.py"],
            check=True,
            capture_output=True,
            text=True,
        )
        payload = json.loads(result.stdout)

        self.assertEqual(payload["status"], "bounded-small-text-directional-gates")
        self.assertEqual(payload["missingEvidence"], [])
        self.assertEqual(payload["missingSourceLines"], [])
        self.assertEqual(len(payload["evidence"]), 10)
        self.assertTrue(all(payload["evidence"].values()))
        self.assertEqual(len(payload["sourceLines"]), 9)
        self.assertTrue(all(line > 0 for line in payload["sourceLines"].values()))
        self.assertTrue(payload["claims"]["readWriteDataGatesIndependent"])
        self.assertTrue(payload["claims"]["smallUtf8TextBounded"])
        self.assertFalse(payload["claims"]["clipboardDataPathEnabledByDefault"])
        self.assertTrue(payload["claims"]["clipboardDataPathExplicitOptInCapable"])
        self.assertFalse(payload["claims"]["richClipboardImplemented"])
        self.assertFalse(payload["remainingBoundary"]["directionalXPCUIRequired"])
        self.assertFalse(
            payload["remainingBoundary"]["eventDrivenDynamicBackoffRequired"]
        )
        self.assertFalse(
            payload["remainingBoundary"]["temporaryObjectCleanupRequired"]
        )
        self.assertFalse(
            payload["remainingBoundary"]["viewerSmallTextClipboardAPIRequired"]
        )
        self.assertFalse(
            payload["remainingBoundary"]["explicitProductEnablementRequired"]
        )
        self.assertEqual(
            payload["nextImplementationBoundary"],
            "host-small-text-clipboard-installed-two-mac-acceptance",
        )


if __name__ == "__main__":
    unittest.main()
