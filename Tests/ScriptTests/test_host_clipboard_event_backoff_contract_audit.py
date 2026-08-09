import json
from pathlib import Path
import subprocess
import unittest


class HostClipboardEventBackoffContractAuditTests(unittest.TestCase):
    def test_listener_is_event_first_with_bounded_macos_fallback(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-clipboard-event-backoff-contract.py",
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
            "farpane-host-clipboard-event-backoff-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"],
            "event-first-bounded-macos-fallback",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertTrue(document["claims"]["listenerEventPathIsPrimary"])
        self.assertTrue(document["claims"]["macFallbackBackoffIsBounded"])
        self.assertTrue(document["claims"]["activityResetsFallbackBackoff"])
        self.assertFalse(document["claims"]["nonHostUpstreamBehaviorChanged"])
        self.assertFalse(document["claims"]["clipboardEnabledByDefault"])
        self.assertTrue(all(document["remainingBoundary"].values()))
        self.assertEqual(
            document["nextImplementationBoundary"],
            "temporary-clipboard-object-cleanup-contract",
        )


if __name__ == "__main__":
    unittest.main()
