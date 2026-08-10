import json
from pathlib import Path
import subprocess
import unittest


class HostClipboardBootstrapHomeOptInContractAuditTests(unittest.TestCase):
    def test_product_opt_in_is_versioned_directional_and_default_off(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-clipboard-bootstrap-home-opt-in-contract.py",
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
            "farpane-host-clipboard-bootstrap-home-opt-in-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "host-clipboard-bootstrap-home-opt-in-ready",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertFalse(document["claims"]["legacyConfigurationEnablesClipboard"])
        self.assertFalse(document["claims"]["clipboardEnabledByDefault"])
        self.assertTrue(document["claims"]["independentHomeOptInAvailable"])
        self.assertTrue(
            document["claims"]["endToEndSmallTextExplicitOptInCapable"]
        )
        self.assertFalse(document["claims"]["richClipboardEnabled"])
        self.assertTrue(all(document["remainingBoundary"].values()))
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-small-text-clipboard-installed-two-mac-acceptance",
        )


if __name__ == "__main__":
    unittest.main()
