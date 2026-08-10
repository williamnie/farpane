import json
from pathlib import Path
import subprocess
import unittest


class HostClipboardExplicitPolicyABIContractAuditTests(unittest.TestCase):
    def test_host_policy_is_representable_but_product_stays_default_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-clipboard-explicit-policy-abi-contract.py",
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
            "farpane-host-clipboard-explicit-policy-abi-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "host-clipboard-explicit-policy-abi-ready-default-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        implementation = document["implementation"]
        self.assertEqual(implementation["hostABIVersion"], 13)
        self.assertTrue(all(implementation["evidence"].values()))
        self.assertTrue(all(implementation["sourceLines"].values()))
        self.assertTrue(document["claims"]["hostDirectionsRepresentable"])
        self.assertTrue(document["claims"]["hostDirectionsDefaultOff"])
        self.assertFalse(
            document["claims"]["currentProductHostClipboardEnabled"]
        )
        self.assertFalse(document["claims"]["endToEndClipboardEnabled"])
        self.assertFalse(document["claims"]["richClipboardEnabled"])
        self.assertTrue(all(document["remainingBoundary"].values()))
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-clipboard-bootstrap-home-opt-in-contract",
        )


if __name__ == "__main__":
    unittest.main()
