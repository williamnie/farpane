#!/usr/bin/env python3
"""Regression tests for the H6.3l machine-readable audit."""

from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path


class ViewerUploadProductActionLifecycleAuditTests(unittest.TestCase):
    def test_current_repository_passes(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            [
                str(repository / "Scripts/audit-host-file-transfer-viewer-upload-product-action-lifecycle.py")
            ],
            cwd=repository,
            check=True,
            capture_output=True,
            text=True,
        )
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload["status"],
            "viewer-upload-product-action-implemented",
        )
        self.assertEqual(payload["missingEvidence"], [])
        self.assertEqual(payload["missingSourceLines"], [])
        self.assertTrue(
            payload["claims"]["viewerUploadProductActionImplemented"]
        )
        self.assertFalse(payload["claims"]["uploadSourcePathsCrossABI"])
        self.assertFalse(
            payload["claims"]["installedSingleMacSmokeComplete"]
        )
        self.assertFalse(payload["claims"]["twoMacAcceptanceComplete"])
        self.assertEqual(
            payload["nextImplementationBoundary"],
            "host-file-transfer-installed-single-mac-smoke",
        )


if __name__ == "__main__":
    unittest.main()
