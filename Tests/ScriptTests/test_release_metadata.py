from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]


class ReleaseMetadataTests(unittest.TestCase):
    def test_repository_declares_agpl_and_bilingual_readme(self) -> None:
        license_text = (REPO_ROOT / "LICENSE").read_text(encoding="utf-8")
        readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")

        self.assertIn("GNU AFFERO GENERAL PUBLIC LICENSE", license_text)
        self.assertIn("## 中文", readme)
        self.assertIn("## English", readme)

    def test_distributable_app_bundles_required_notices(self) -> None:
        script = (REPO_ROOT / "Scripts" / "build-universal.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn('cp "$repo_dir/LICENSE"', script)
        self.assertIn("ThirdPartyLicenses", script)
        for package in ("libyuv", "aom", "libvpx", "opus"):
            self.assertIn(f'"$vcpkg_license_root/{package}/copyright"', script)

    def test_release_workflow_verifies_before_publishing(self) -> None:
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("swift test", workflow)
        self.assertIn("--verify-tag", workflow)
        self.assertIn("--prerelease", workflow)


if __name__ == "__main__":
    unittest.main()
