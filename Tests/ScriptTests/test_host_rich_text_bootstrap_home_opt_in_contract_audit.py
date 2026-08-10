import json
import subprocess
import unittest
from pathlib import Path


class HostRichTextBootstrapHomeOptInContractAuditTests(unittest.TestCase):
    def test_host_rich_text_requires_explicit_product_opt_in(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            [
                "python3",
                str(
                    repository
                    / "Scripts/audit-host-rich-text-bootstrap-home-opt-in-contract.py"
                ),
            ],
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        document = json.loads(result.stdout)
        self.assertEqual(
            document["status"],
            "host-rich-text-bootstrap-home-opt-in-ready",
        )
        self.assertTrue(all(document["evidence"].values()))
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertFalse(document["claims"]["richTextEnabledByDefault"])
        self.assertTrue(
            document["claims"]["independentHostRichTextOptInAvailable"]
        )
        self.assertTrue(
            document["claims"]["endToEndRichTextExplicitOptInCapable"]
        )
        self.assertTrue(document["claims"]["imageClipboardEnabled"])
        self.assertFalse(document["claims"]["filePromiseClipboardEnabled"])
        self.assertFalse(
            document["remainingBoundary"]["imageImplementationRequired"]
        )
        self.assertTrue(
            document["remainingBoundary"]["filePromiseImplementationRequired"]
        )
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-image-clipboard-installed-two-mac-acceptance",
        )


if __name__ == "__main__":
    unittest.main()
