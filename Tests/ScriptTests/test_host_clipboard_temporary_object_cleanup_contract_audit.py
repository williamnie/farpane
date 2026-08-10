import json
from pathlib import Path
import subprocess
import unittest


class HostClipboardTemporaryObjectCleanupContractAuditTests(unittest.TestCase):
    def test_transient_objects_and_provider_are_drained_on_teardown(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-clipboard-temporary-object-cleanup-contract.py",
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
            "farpane-host-clipboard-temporary-object-cleanup-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "temporary-clipboard-objects-cleaned-on-teardown",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(document["claims"]["smallTextTransientCacheCleared"])
        self.assertTrue(document["claims"]["promiseProviderTeardownImplemented"])
        self.assertTrue(document["claims"]["newerLocalClipboardPreserved"])
        self.assertFalse(document["claims"]["richClipboardEnabledByDefault"])
        self.assertFalse(document["claims"]["filePromiseCompiledInCurrentProduct"])
        self.assertFalse(
            document["remainingBoundary"]["viewerSmallTextClipboardAPIRequired"]
        )
        self.assertFalse(
            document["remainingBoundary"]["viewerSmallTextClipboardAPIRequired"]
        )
        self.assertFalse(
            document["remainingBoundary"]["explicitProductEnablementRequired"]
        )
        self.assertFalse(
            document["remainingBoundary"]["richPayloadTransferRequired"]
        )
        self.assertTrue(
            document["remainingBoundary"]["physicalOwnershipAndTeardownAcceptanceRequired"]
        )
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-rich-text-clipboard-installed-two-mac-acceptance",
        )


if __name__ == "__main__":
    unittest.main()
