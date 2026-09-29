"""Small structural boundaries; behavior belongs in Swift/Rust/runtime tests."""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ArchitectureBoundaryTests(unittest.TestCase):
    def test_core_bridge_does_not_own_ui_capture_or_codec_frameworks(self):
        forbidden = {"AppKit", "SwiftUI", "ScreenCaptureKit", "VideoToolbox", "MetalKit"}
        for source in (ROOT / "Sources/CoreBridge").glob("*.swift"):
            with self.subTest(source=source.name):
                imports = set(re.findall(r"^import (\w+)", source.read_text(), re.MULTILINE))
                self.assertFalse(imports & forbidden)

    def test_viewer_pasteboard_has_one_native_owner(self):
        owners = []
        for source in (ROOT / "Sources").rglob("*.swift"):
            text = source.read_text()
            if re.search(r"^import AppKit$", text, re.MULTILINE) and re.search(r"\bNSPasteboard\b", text):
                owners.append(source.relative_to(ROOT / "Sources").as_posix())
        self.assertEqual(owners, ["RustDeskNative/ViewerPasteboardOwner.swift"])

    def test_public_abi_versions_agree_with_the_canonical_rust_entrypoints(self):
        header = (ROOT / "CoreBridge/include/rustdesk_native.h").read_text()
        for file, rust_name, c_name in [
            ("rdn_bridge.rs", "ABI_VERSION", "RDN_ABI_VERSION"),
            ("rdn_host_bridge.rs", "HOST_ABI_VERSION", "RDN_HOST_ABI_VERSION"),
            ("rdn_host_bridge.rs", "HOST_MEDIA_ABI_VERSION", "RDN_HOST_MEDIA_ABI_VERSION"),
        ]:
            with self.subTest(contract=c_name):
                source = (ROOT / "CoreBridge/RustDeskPatch" / file).read_text()
                rust = re.search(rf"const {rust_name}: u32 = (\d+);", source).group(1)
                c = re.search(rf"#define {c_name} (\d+)u", header).group(1)
                self.assertEqual(rust, c)


if __name__ == "__main__":
    unittest.main()
