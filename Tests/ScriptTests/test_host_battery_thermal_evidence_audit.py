import json
import subprocess
import unittest
from pathlib import Path


class HostBatteryThermalEvidenceAuditTests(unittest.TestCase):
    def test_item_nine_battery_thermal_checkpoint_is_frozen(self):
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-battery-thermal-evidence.py"],
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
            "farpane-host-battery-thermal-evidence-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["section15_2Item"], 9)
        self.assertEqual(document["status"], "checkpoint-required")
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(all(document["remainingBoundary"].values()))

        contract = document["targetContract"]
        self.assertEqual(
            contract["requiredRuns"]["batteryIdle"]["scenario"],
            "host-ready-no-screen-route",
        )
        self.assertEqual(
            contract["requiredRuns"]["batteryActive"]["scenario"],
            "1080p30",
        )
        self.assertTrue(
            contract["energyEvidence"]["requiresNamedPhysicalAuthorityAndUnit"]
        )
        self.assertTrue(
            contract["thermalEvidence"]["requiresSeriousCriticalCadenceDegradation"]
        )
        self.assertIn(
            "top-relative-power-as-joules-or-watt-hours",
            contract["forbiddenInference"],
        )


if __name__ == "__main__":
    unittest.main()
