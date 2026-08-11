#!/usr/bin/env python3
"""Regression tests for the H6.3f2b2s machine-readable audit."""

from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path


class ViewerDownloadPickerActionLifecycleAuditTests(unittest.TestCase):
    def test_current_repository_passes(self) -> None:
        repository = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            [
                str(repository / "Scripts/audit-host-file-transfer-viewer-download-picker-action-lifecycle.py")
            ],
            cwd=repository,
            check=True,
            capture_output=True,
            text=True,
        )
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload["status"],
            "viewer-download-picker-action-implemented-host-opt-in-off",
        )
        self.assertEqual(payload["missingEvidence"], [])
        self.assertEqual(payload["missingSourceLines"], [])
        self.assertTrue(payload["claims"]["viewerDownloadPickerActionImplemented"])
        self.assertTrue(payload["claims"]["viewerActionIsOneShot"])
        self.assertFalse(payload["claims"]["hostReceiveRootOptInImplemented"])
        self.assertFalse(payload["claims"]["endToEndProductFileTransferEnabled"])
        self.assertFalse(payload["claims"]["twoMacAcceptanceComplete"])
        self.assertEqual(
            payload["nextImplementationBoundary"],
            "host-file-transfer-host-home-receive-root-opt-in-lifecycle",
        )


if __name__ == "__main__":
    unittest.main()
