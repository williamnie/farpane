import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferSecurityBoundaryAuditTests(unittest.TestCase):
    def test_security_gaps_fail_product_enablement_closed(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-file-transfer-security-boundary.py"],
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
            "farpane-host-file-transfer-security-boundary-audit",
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["status"], "audited-not-product-ready")
        self.assertEqual(document["missingEstablishedGuards"], [])
        self.assertEqual(document["missingExpectedGaps"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["establishedGuards"].values()))
        self.assertTrue(all(document["openGaps"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertFalse(claims["productEnablementSafe"])
        self.assertFalse(claims["nativeHostFileTransferFunctional"])
        self.assertTrue(claims["pathTraversalGuardPresent"])
        self.assertFalse(claims["symlinkRaceClosed"])
        self.assertTrue(claims["compressedPayloadBounded"])
        self.assertTrue(claims["safeReceiveRootPrimitiveImplemented"])
        self.assertTrue(claims["safeRootMutationsImplemented"])
        self.assertTrue(claims["nativeHostFileServiceOwnerCoreImplemented"])
        self.assertTrue(claims["safeMutationConnectionDispatchImplemented"])
        self.assertTrue(claims["nativeNewFileWriteLifecycleImplemented"])
        self.assertTrue(claims["nativeResumeDigestLifecycleImplemented"])
        self.assertTrue(
            claims["nativeReadListDownloadConnectionLifecycleImplemented"]
        )
        self.assertTrue(claims["viewerDestinationProgressContractImplemented"])
        self.assertFalse(claims["clipboardFilePromiseEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-viewer-core-event-command-runtime-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
