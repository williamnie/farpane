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
        self.assertFalse(any(document["claims"].values()))
        self.assertFalse(
            document["remainingBoundary"]["independentRevocationCommandsRequired"]
        )
        self.assertFalse(document["remainingBoundary"]["directionalXPCUIRequired"])
        self.assertTrue(all(
            value for name, value in document["remainingBoundary"].items()
            if name not in {
                "independentRevocationCommandsRequired",
                "directionalXPCUIRequired",
            }
        ))
        self.assertEqual(
            document["nextImplementationBoundary"],
            "event-first-dynamic-backoff-contract",
        )


if __name__ == "__main__":
    unittest.main()
