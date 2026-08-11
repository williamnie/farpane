import json
from pathlib import Path
import subprocess
import unittest


class HostClipboardExplicitPolicyABIContractAuditTests(unittest.TestCase):
    def test_host_policy_is_representable_default_off_and_explicitly_projected(self) -> None:
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
        self.assertEqual(implementation["hostABIVersion"], 19)
        self.assertTrue(all(implementation["evidence"].values()))
        self.assertTrue(all(implementation["sourceLines"].values()))
        self.assertTrue(document["claims"]["hostDirectionsRepresentable"])
        self.assertTrue(document["claims"]["hostDirectionsDefaultOff"])
        self.assertTrue(document["claims"]["hostProductExplicitOptInCapable"])
        self.assertTrue(
            document["claims"]["endToEndSmallTextExplicitOptInCapable"]
        )
        self.assertTrue(document["claims"]["richClipboardEnabled"])
        self.assertTrue(document["claims"]["richClipboardTransportCapable"])
        self.assertFalse(
            document["remainingBoundary"]["backgroundBootstrapPropagationRequired"]
        )
        self.assertFalse(document["remainingBoundary"]["homeOptInControlsRequired"])
        self.assertTrue(document["remainingBoundary"]["installedTwoMacAcceptanceRequired"])
        self.assertFalse(document["remainingBoundary"]["richPayloadTransferRequired"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-rich-text-clipboard-installed-two-mac-acceptance",
        )


if __name__ == "__main__":
    unittest.main()
