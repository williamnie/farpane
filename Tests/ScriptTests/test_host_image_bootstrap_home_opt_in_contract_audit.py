import json
from pathlib import Path
import subprocess
import unittest


class HostImageBootstrapHomeOptInContractAuditTests(unittest.TestCase):
    def test_host_image_requires_explicit_product_opt_in(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-image-bootstrap-home-opt-in-contract.py",
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
            "farpane-host-image-bootstrap-home-opt-in-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "host-image-bootstrap-home-opt-in-ready",
        )
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])

        claims = document["claims"]
        self.assertFalse(claims["legacyConfigurationEnablesImage"])
        self.assertFalse(claims["hostImageEnabledByDefault"])
        self.assertTrue(claims["independentHostImageOptInAvailable"])
        self.assertTrue(claims["endToEndImageExplicitOptInCapable"])
        self.assertFalse(claims["svgSanitizedForRendering"])
        self.assertFalse(claims["filePromiseClipboardEnabled"])

        remaining = document["remainingBoundary"]
        self.assertTrue(
            remaining["installedTwoMacImageClipboardAcceptanceRequired"]
        )
        self.assertTrue(
            remaining["physicalOwnershipAndTeardownAcceptanceRequired"]
        )
        self.assertTrue(remaining["physicalLatencyAndIdleCPUAcceptanceRequired"])
        self.assertTrue(remaining["filePromiseImplementationRequired"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-image-clipboard-installed-two-mac-acceptance",
        )


if __name__ == "__main__":
    unittest.main()
