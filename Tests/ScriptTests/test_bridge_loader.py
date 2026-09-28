"""Exercise the real C loader against complete, partial and incompatible dylibs."""

import ctypes
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEADER = (ROOT / "CoreBridge/include/rustdesk_native.h").read_text()
# The public header is the contract, independent of the loader's symbol table.
SYMBOLS = sorted(set(re.findall(r"\b(rdn_(?:client_|core_|host_)\w+)\s*\(", HEADER)))
VIEWER = [name for name in SYMBOLS if not name.startswith("rdn_host_")]
HOST = [name for name in SYMBOLS if name.startswith("rdn_host_")]
ABI = int(re.search(r"#define RDN_ABI_VERSION (\d+)u", HEADER).group(1))


class BridgeLoaderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.directory = Path(cls.temporary.name)
        library = cls.directory / "shim.dylib"
        subprocess.run([
            "xcrun", "clang", "-dynamiclib", "-Wall", "-Werror",
            "-I", str(ROOT / "CoreBridge/include"),
            str(ROOT / "CoreBridge/Shim/rdn_shim.c"),
            "-framework", "ApplicationServices", "-o", str(library),
        ], check=True, capture_output=True)
        cls.shim = ctypes.CDLL(str(library))
        cls.shim.rdn_shim_open.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t]
        cls.shim.rdn_shim_open.restype = ctypes.c_void_p
        cls.shim.rdn_shim_close.argtypes = [ctypes.c_void_p]
        cls.shim.rdn_shim_host_available.argtypes = [ctypes.c_void_p]

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def library(self, name, *, omitted=(), abi=ABI):
        source = self.directory / (name + ".c")
        # Only abi_version is called; remaining stubs exist solely for dlsym.
        source.write_text("\n".join(
            f"unsigned {symbol}(void) {{ return {abi if symbol == 'rdn_core_abi_version' else 0}; }}"
            for symbol in SYMBOLS if symbol not in omitted
        ))
        target = source.with_suffix(".dylib")
        subprocess.run(["xcrun", "clang", "-dynamiclib", str(source), "-o", str(target)],
                       check=True, capture_output=True)
        return target

    def open(self, path):
        error = ctypes.create_string_buffer(1024)
        handle = self.shim.rdn_shim_open(str(path).encode(), error, len(error))
        return handle, error.value.decode()

    def test_complete_library_and_viewer_only_library_load(self):
        for name, omitted, expected in [("complete", (), 1), ("viewer", HOST, 0)]:
            with self.subTest(name=name):
                handle, error = self.open(self.library(name, omitted=omitted))
                self.assertTrue(handle, error)
                try:
                    self.assertEqual(self.shim.rdn_shim_host_available(handle), expected)
                finally:
                    self.shim.rdn_shim_close(handle)

    def test_every_required_viewer_symbol_is_checked(self):
        for symbol in VIEWER:
            with self.subTest(symbol=symbol):
                handle, error = self.open(self.library("missing_" + symbol, omitted=[symbol]))
                if handle:
                    self.shim.rdn_shim_close(handle)
                self.assertFalse(handle)
                self.assertIn("missing required ABI symbols", error)

    def test_any_missing_host_symbol_disables_the_whole_optional_surface(self):
        for symbol in HOST:
            with self.subTest(symbol=symbol):
                handle, error = self.open(self.library("missing_" + symbol, omitted=[symbol]))
                self.assertTrue(handle, error)
                try:
                    self.assertEqual(self.shim.rdn_shim_host_available(handle), 0)
                finally:
                    self.shim.rdn_shim_close(handle)

    def test_incompatible_version_is_rejected(self):
        handle, error = self.open(self.library("incompatible", abi=ABI + 1))
        if handle:
            self.shim.rdn_shim_close(handle)
        self.assertFalse(handle)
        self.assertEqual(error, "core ABI version mismatch")


if __name__ == "__main__":
    unittest.main()
