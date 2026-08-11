from pathlib import Path
import subprocess
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
VERIFY_SCRIPT = REPO_ROOT / "Scripts" / "verify-rustdesk-core-source.sh"
PREFLIGHT_SCRIPT = REPO_ROOT / "Scripts" / "preflight-host-mode-h1-golden.sh"
VENDOR_ROOT = REPO_ROOT / "Vendor" / "rustdesk"
HBB_COMMON_ROOT = VENDOR_ROOT / "libs" / "hbb_common"


def git_status(repository: Path) -> str:
    return subprocess.run(
        ["git", "status", "--short"],
        cwd=repository,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


class VerifyRustDeskCoreSourceTests(unittest.TestCase):
    def test_verifies_current_patch_stack_without_mutating_checkouts(self) -> None:
        self.assertTrue(
            VERIFY_SCRIPT.is_file(),
            "Scripts/verify-rustdesk-core-source.sh must exist",
        )

        before = (git_status(VENDOR_ROOT), git_status(HBB_COMMON_ROOT))
        result = subprocess.run(
            [str(VERIFY_SCRIPT)],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        after = (git_status(VENDOR_ROOT), git_status(HBB_COMMON_ROOT))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(
            result.stdout,
            r"\ARUSTDESK_CORE_SOURCE_VERIFIED commit=[0-9a-f]{40}\n\Z",
        )
        self.assertEqual(after, before)

    def test_golden_preflight_uses_current_read_only_verifier(self) -> None:
        preflight = PREFLIGHT_SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            '"$repo_dir/Scripts/verify-rustdesk-core-source.sh"',
            preflight,
        )
        self.assertNotIn(
            "CoreBridge/RustDeskPatch/upstream-1.4.9.patch",
            preflight,
        )


if __name__ == "__main__":
    unittest.main()
