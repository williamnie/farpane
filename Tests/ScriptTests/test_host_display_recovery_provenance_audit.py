import json
import subprocess
import unittest
from pathlib import Path


class HostDisplayRecoveryProvenanceAuditTests(unittest.TestCase):
    def test_ambiguous_route_replacement_requires_versioned_provenance(self):
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-display-recovery-provenance.py",
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
            "farpane-host-display-recovery-provenance-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["status"], "display-callback-implemented")
        self.assertEqual(document["missingEvidence"], [])

        implementation = document["implementation"]
        self.assertEqual(implementation["hostControlABI"], 14)
        self.assertEqual(implementation["hostEventEnvelopeSchema"], 1)
        self.assertEqual(implementation["hostMediaABI"], 1)
        self.assertTrue(all(implementation["evidence"].values()))
        self.assertTrue(all(implementation["sourceLines"].values()))

        target = document["targetContract"]
        self.assertEqual(target["versioning"]["hostControlABI"], 14)
        self.assertEqual(target["versioning"]["hostMediaABI"], 1)
        self.assertEqual(
            target["rustAuthority"]["acceptedEventType"],
            "mediaDisplayReconfigureStarted",
        )
        self.assertEqual(
            target["replacementControlProvenance"]["requiredOn"],
            ["startCapture", "reconfigure"],
        )
        self.assertTrue(
            target["replacementControlProvenance"]
            ["mustMatchAcceptedMarkerExactly"]
        )
        self.assertTrue(all(document["remainingBoundary"].values()))


if __name__ == "__main__":
    unittest.main()
