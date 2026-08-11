import json
from pathlib import Path
import subprocess
import unittest


class HostMultiDisplayProductDevelopmentCompletionAuditTests(
    unittest.TestCase
):
    def test_h6_4_product_development_is_complete_without_claiming_acceptance(
        self,
    ) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-multi-display-product-development-completion.py",
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
            "farpane-host-multi-display-product-development-completion-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["status"], "product-development-complete")
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertEqual(document["remainingDevelopmentGaps"], [])
        claims = document["claims"]
        self.assertTrue(claims["viewerCatalogImplemented"])
        self.assertTrue(claims["viewerSelectionLifecycleImplemented"])
        self.assertTrue(claims["hostSwitchValidationImplemented"])
        self.assertTrue(claims["viewerInputQuiescenceImplemented"])
        self.assertTrue(claims["viewerDisplaySelectorImplemented"])
        self.assertTrue(claims["multiDisplayProductDevelopmentComplete"])
        self.assertFalse(claims["installedCurrentBuildSmokeComplete"])
        self.assertFalse(claims["twoMacMultiDisplayAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-audio-product-ownership-audit",
        )


if __name__ == "__main__":
    unittest.main()
