import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferConnectionMutationDispatchAuditTests(unittest.TestCase):
    def test_safe_mutations_are_dispatched_without_opening_write_jobs(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-connection-mutation-dispatch.py",
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
            "farpane-host-file-transfer-connection-mutation-dispatch-audit",
        )
        self.assertEqual(
            document["status"],
            "native-file-mutations-dispatched-write-jobs-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["safeMutationConnectionDispatchImplemented"])
        self.assertFalse(claims["recursiveRemovalImplemented"])
        self.assertFalse(claims["nativeWriteJobLifecycleImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-native-write-job-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
