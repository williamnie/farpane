import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Scripts"))
from validate_tcc_rebuild import select_builds  # noqa: E402


class TCCRebuildValidatorTests(unittest.TestCase):
    def test_selects_distinct_code_with_stable_requirement(self):
        records = [
            (
                "rebuild",
                {
                    "buildNumber": "2",
                    "codeDirectoryHash": "new-code",
                    "designatedRequirementSHA256": "stable-requirement",
                },
            ),
            (
                "baseline",
                {
                    "buildNumber": "1",
                    "codeDirectoryHash": "old-code",
                    "designatedRequirementSHA256": "stable-requirement",
                },
            ),
        ]

        baseline, rebuild = select_builds(records, "2")

        self.assertEqual(baseline[0], "baseline")
        self.assertEqual(rebuild[0], "rebuild")

    def test_rejects_same_code_directory(self):
        records = [
            (
                "rebuild",
                {
                    "buildNumber": "2",
                    "codeDirectoryHash": "same-code",
                    "designatedRequirementSHA256": "stable-requirement",
                },
            ),
            (
                "baseline",
                {
                    "buildNumber": "1",
                    "codeDirectoryHash": "same-code",
                    "designatedRequirementSHA256": "stable-requirement",
                },
            ),
        ]

        with self.assertRaisesRegex(ValueError, "same signing requirement"):
            select_builds(records, "2")

    def test_rejects_changed_designated_requirement(self):
        records = [
            (
                "rebuild",
                {
                    "buildNumber": "2",
                    "codeDirectoryHash": "new-code",
                    "designatedRequirementSHA256": "new-requirement",
                },
            ),
            (
                "baseline",
                {
                    "buildNumber": "1",
                    "codeDirectoryHash": "old-code",
                    "designatedRequirementSHA256": "old-requirement",
                },
            ),
        ]

        with self.assertRaisesRegex(ValueError, "same signing requirement"):
            select_builds(records, "2")

    def test_requires_current_build_preflight(self):
        with self.assertRaisesRegex(ValueError, "current installed build"):
            select_builds([], "2")


if __name__ == "__main__":
    unittest.main()
