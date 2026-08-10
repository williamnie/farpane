import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferSafeReceiveRootAuditTests(unittest.TestCase):
    def test_descriptor_relative_receive_root_is_implemented_but_not_wired(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            ["python3", "Scripts/audit-host-file-transfer-safe-receive-root.py"],
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
            "farpane-host-file-transfer-safe-receive-root-audit",
        )
        self.assertEqual(
            document["status"],
            "descriptor-relative-receive-root-primitive-implemented-product-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertTrue(claims["descriptorRelativeRootPrimitiveImplemented"])
        self.assertTrue(claims["safeCreateAndResumePrimitiveImplemented"])
        self.assertTrue(claims["rootPathReplacementCannotRedirectOpenDescriptor"])
        self.assertTrue(claims["safeRemoveAndRenameImplemented"])
        self.assertTrue(claims["nativeHostFileServiceOwnerCoreImplemented"])
        self.assertFalse(claims["nativeHostFileServiceOwnerImplemented"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["twoMacAcceptanceComplete"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-connection-mutation-dispatch",
        )


if __name__ == "__main__":
    unittest.main()
