import json
from pathlib import Path
import subprocess
import unittest


class HostFileTransferBoundedBlockEnvelopeAuditTests(unittest.TestCase):
    def test_file_blocks_are_bounded_before_any_file_open(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [
                "python3",
                "Scripts/audit-host-file-transfer-bounded-block-envelope.py",
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
            "farpane-host-file-transfer-bounded-block-envelope-audit",
        )
        self.assertEqual(
            document["status"],
            "bounded-file-block-envelope-implemented-product-off",
        )
        self.assertEqual(document["missingEvidence"], [])
        self.assertEqual(document["missingSourceLines"], [])
        self.assertTrue(all(document["evidence"].values()))
        self.assertTrue(all(document["sourceLines"].values()))
        claims = document["claims"]
        self.assertEqual(claims["wireBlockLimitBytes"], 128 * 1024)
        self.assertEqual(claims["decodedBlockLimitBytes"], 128 * 1024)
        self.assertTrue(claims["compressedPayloadBounded"])
        self.assertFalse(claims["productFileTransferEnabled"])
        self.assertFalse(claims["symlinkRaceClosed"])
        self.assertFalse(claims["nativeHostFileServiceOwnerImplemented"])
        self.assertTrue(claims["nativeHostFileServiceOwnerCoreImplemented"])
        self.assertTrue(claims["safeReceiveRootPrimitiveImplemented"])
        self.assertTrue(claims["safeRootMutationsImplemented"])
        self.assertEqual(
            document["nextImplementationBoundary"],
            "host-file-transfer-receive-root-config-contract",
        )


if __name__ == "__main__":
    unittest.main()
