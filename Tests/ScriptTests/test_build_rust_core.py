from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]


class BuildRustCoreScriptTests(unittest.TestCase):
    def test_publishes_validated_core_with_same_directory_atomic_replace(self) -> None:
        script = (REPO_ROOT / "Scripts" / "build-rust-core.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn(
            'staged_core=$(mktemp "$output_dir/.liblibrustdesk.dylib.XXXXXX")',
            script,
        )
        self.assertIn('cp -p "$source_core" "$staged_core"', script)
        self.assertIn('trap cleanup_staged_core EXIT', script)
        self.assertIn('mv -f "$staged_core" "$published_core"', script)
        self.assertNotIn(
            'cp "$vendor_dir/target/release/liblibrustdesk.dylib" "$output_dir/"',
            script,
        )

        publish_index = script.index('mv -f "$staged_core" "$published_core"')
        validations = [
            index
            for marker in ('file "$staged_core"', 'nm -gU "$staged_core"')
            for index in [script.find(marker)]
        ]
        self.assertTrue(all(index >= 0 for index in validations))
        self.assertTrue(all(index < publish_index for index in validations))


if __name__ == "__main__":
    unittest.main()
