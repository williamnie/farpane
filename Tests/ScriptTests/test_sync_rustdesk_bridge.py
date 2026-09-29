import importlib.util
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("bridge_sync", ROOT / "Scripts/sync-rustdesk-bridge.py")
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


class BridgeSourceSyncTests(unittest.TestCase):
    def test_copy_and_read_only_check_cover_nested_fragments(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            SYNC.sync(target)
            self.assertEqual(SYNC.sync(target, check=True), [])
            fragment = next(target.glob("rdn_host_bridge/tests/*.rs"))
            fragment.write_text("modified test body")
            before = fragment.read_bytes()
            self.assertEqual(SYNC.sync(target, check=True), [fragment.relative_to(target).as_posix()])
            self.assertEqual(fragment.read_bytes(), before)
            SYNC.sync(target)
            self.assertEqual(SYNC.sync(target, check=True), [])

    def test_every_include_is_copied_and_resolves_inside_canonical_tree(self):
        sources = set(SYNC.sources())
        included = set()
        for source in sources:
            for relative in re.findall(r'include!\("([^"]+)"\)', source.read_text()):
                target = source.parent / relative
                self.assertIn(target, sources)
                self.assertNotIn(target, included, "fragment included more than once")
                included.add(target)
        self.assertEqual(included, {path for path in sources if path.parent != SYNC.CANONICAL})


if __name__ == "__main__":
    unittest.main()
