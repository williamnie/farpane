import json
import subprocess
import unittest
from pathlib import Path


class HostPhysicalEnergyAuthorityAuditTests(unittest.TestCase):
    def test_privileged_powermetrics_authority_is_frozen(self):
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-physical-energy-authority.py"],
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
            "farpane-host-physical-energy-authority-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["section15_2Item"], 9)
        self.assertEqual(document["status"], "privileged-authority-selected")
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(all(document["remainingBoundary"].values()))

        authority = document["selectedAuthority"]
        self.assertEqual(authority["executable"], "/usr/bin/powermetrics")
        self.assertEqual(authority["format"], "nul-separated-plist")
        self.assertEqual(
            authority["privilege"],
            "operator-explicit-superuser-acceptance-only",
        )
        self.assertFalse(
            authority["perProcessEnergyImpactAcceptedAsPhysicalEnergy"]
        )

        capture = document["captureContract"]
        self.assertEqual(capture["minimumDurationSeconds"], 600)
        self.assertEqual(capture["sampleIntervalMilliseconds"], 1000)
        self.assertFalse(capture["productMayRequestOrEscalatePrivileges"])
        self.assertFalse(capture["captureToolMayEmbedOrInvokeSudo"])
        self.assertIn(
            "guessed-plist-schema-without-real-portable-mac-fixture",
            document["forbiddenInference"],
        )


if __name__ == "__main__":
    unittest.main()
