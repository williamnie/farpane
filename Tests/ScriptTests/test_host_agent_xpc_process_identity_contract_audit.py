import json
from pathlib import Path
import subprocess
import unittest


class HostAgentXPCProcessIdentityContractAuditTests(unittest.TestCase):
    def test_process_identity_xpc_v2_contract_is_implemented(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-agent-xpc-process-identity-contract.py",
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
            "farpane-host-agent-xpc-process-identity-contract-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(
            document["status"], "application-host-observation-composed"
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        self.assertFalse(
            document["remainingBoundary"]
            ["applicationHostObservationStillRequiresComposition"]
        )
        self.assertTrue(
            document["remainingBoundary"]
            ["viewerAutomaticRecoveryStillRequiresImplementation"]
        )
        self.assertEqual(
            document["nextImplementationBoundary"],
            "viewer-automatic-recovery-composition",
        )
        self.assertTrue(
            document["evidence"]["handshakeImplementsStrictSchemaAndWireV2"]
        )
        self.assertTrue(
            document["evidence"]
            ["productAuthorityCapturesAndHashesExactCurrentProcessOnce"]
        )
        self.assertTrue(
            document["evidence"]
            ["sameConnectionPinsFullIdentityAcrossTrafficAndReconnect"]
        )
        self.assertTrue(
            document["evidence"]
            ["applicationHostCompositionUsesOnlyCoherentProjection"]
        )
        self.assertTrue(
            document["evidence"]
            ["applicationHostObservationUsesExactXPCProcessIdentity"]
        )

        contract = document["targetContract"]
        self.assertEqual(contract["handshakeSchemaVersion"], 2)
        self.assertEqual(contract["wireVersion"], 2)
        self.assertEqual(
            contract["identityFields"],
            [
                "agentBuildID",
                "hostInstanceID",
                "agentBootID",
                "agentProcessID",
                "agentProcessStartIdentitySHA256",
            ],
        )
        self.assertEqual(
            contract["agentAuthority"]["processIDSource"], "getpid"
        )
        self.assertEqual(
            contract["agentAuthority"]["processStartSource"],
            "PROC_PIDTBSDINFO-same-pid",
        )
        self.assertTrue(
            contract["validation"]["requiresAgentProcessIDGreaterThanOne"]
        )
        self.assertEqual(
            contract["validation"]["requiresProcessStartDigestLength"], 64
        )
        self.assertTrue(
            contract["appBinding"]
            ["acceptsIdentityOnlyFromCompatibleHandshakeV2"]
        )
        self.assertTrue(
            contract["appBinding"]["comparesAllIdentityFieldsAcrossReconnect"]
        )
        self.assertIn(
            "schema-v1-fallback-for-host-lifecycle-evidence",
            contract["forbiddenInference"],
        )


if __name__ == "__main__":
    unittest.main()
