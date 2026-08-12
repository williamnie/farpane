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

    def test_launch_agent_asset_is_bundled_before_app_signing(self) -> None:
        script = (REPO_ROOT / "Scripts" / "build-universal.sh").read_text(
            encoding="utf-8"
        )
        asset_name = "io.rustdesknative.viewer.host-agent.plist"

        self.assertIn(f'App/LaunchAgents/{asset_name}', script)
        self.assertIn(f'Contents/Library/LaunchAgents/{asset_name}', script)
        self.assertIn("plutil -lint", script)
        self.assertLess(
            script.index(f'App/LaunchAgents/{asset_name}'),
            script.index('codesign --force --sign "$signing_identity" --timestamp=none "$app_dir"'),
        )

    def test_host_agent_uses_a_separately_signed_non_app_executable(self) -> None:
        script = (REPO_ROOT / "Scripts" / "build-universal.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn(
            'host_agent_executable="$app_dir/Contents/MacOS/FarPaneHostAgent"',
            script,
        )
        self.assertIn(
            'RC_UUID_SALT="FarPaneHostAgent-$build_architecture" xcrun swiftc',
            script,
        )
        self.assertIn(
            'HostAgent executable must have a distinct Mach-O UUID',
            script,
        )
        helper_signing = script.index(
            '--identifier io.rustdesknative.viewer'
        )
        app_signing = script.index(
            'codesign --force --sign "$signing_identity" --timestamp=none "$app_dir"'
        )
        self.assertLess(helper_signing, app_signing)

    def test_build_architecture_override_is_explicit_and_bounded(self) -> None:
        script = (REPO_ROOT / "Scripts" / "build-universal.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn(
            'RDN_BUILD_ARCHITECTURES:-"arm64 x86_64"', script
        )
        self.assertIn('arm64|x86_64|"arm64 x86_64"', script)
        self.assertIn(
            'RustDesk Core is missing for architecture: $build_architecture',
            script,
        )
        self.assertIn(
            'Swift executable architecture does not match: $build_architecture',
            script,
        )
        self.assertIn(
            'RustDesk Core architecture does not match: $build_architecture',
            script,
        )
        self.assertIn(
            'print "BUILD_ARCHITECTURES=$architecture_spec"', script
        )

    def test_release_workflow_verifies_before_publishing(self) -> None:
        workflow = (REPO_ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("swift test", workflow)
        self.assertIn("--verify-tag", workflow)
        self.assertIn("--prerelease", workflow)


if __name__ == "__main__":
    unittest.main()
