import json
from pathlib import Path
import subprocess
import unittest


class HostIdleAuthenticatedConnectionAuthorityAuditTests(unittest.TestCase):
    def test_shared_target_contract_is_implemented(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-idle-authenticated-connection-authority.py",
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
            "farpane-host-idle-authenticated-connection-authority-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["status"], "implemented")
        self.assertEqual(document["missingEvidence"], [])

        implementation = document["implementation"]
        self.assertEqual(implementation["hostABIVersion"], 16)
        self.assertEqual(implementation["headerABIVersion"], 16)
        self.assertEqual(implementation["snapshotSchemaVersion"], 8)
        self.assertTrue(all(implementation["evidence"].values()))
        self.assertTrue(all(implementation["sourceLines"].values()))

        target = document["targetContract"]
        self.assertEqual(target["hostABIVersion"], 16)
        self.assertEqual(target["hostSnapshotSchemaVersion"], 8)
        self.assertEqual(target["runtimeStateSchemaVersion"], 2)
        self.assertEqual(
            target["hostSnapshotField"], "authenticatedConnectionCount"
        )
        self.assertFalse(target["xpcOuterWireVersionChangeRequired"])
        self.assertIn(
            "noActiveSessionOrMediaRouteInference", target["countSemantics"]
        )
        self.assertIn(
            "allAuthenticatedConnectionsProvenAbsentDerivedNeverHardcoded",
            target["runtimeStateContract"],
        )
        self.assertEqual(
            document["remainingBoundary"],
            {
                "sharedHostSnapshotAndRuntimeEvidenceSchemaChangeRequired": False,
                "backgroundAndLegacyRuntimeStateCallSitesNeedOneAuthority": False,
                "builtCoreLifecycleAndStrictDecoderTestsRequired": False,
                "realHostReadyNoConnection600SecondRunRequired": True,
                "dualArchitectureBaseMatrixStillHasNoRealData": True,
            },
        )


if __name__ == "__main__":
    unittest.main()
