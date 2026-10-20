"""A GUI Rust-only source change cannot reclassify changed dependency inputs."""
import sys
from pathlib import Path
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'packaging'))
from native_notice_delivery import gui_source_baseline


class GuiNoticeBoundary(unittest.TestCase):
    def setUp(self):
        self.baseline = {'Linux/gui/src/viewer.rs':'a', 'Linux/gui/Cargo.lock':'b',
                         'Linux/gui/src/gpu_renderer.c':'c', 'Linux/native/mod.rs':'d'}

    def verify(self, sources, changes):
        return gui_source_baseline(sources, {'schema':1,'base_sources':self.baseline,
                                             'changed_sources':changes})

    def test_gui_only_delta_preserves_original_audit_scope(self):
        sources=dict(self.baseline);sources['Linux/gui/src/viewer.rs']='e'
        self.assertEqual(self.verify(sources,['Linux/gui/src/viewer.rs']),self.baseline)
        self.assertEqual(gui_source_baseline(self.baseline,None),self.baseline)

    def test_dependency_bridge_and_core_changes_are_rejected(self):
        for key in self.baseline.keys()-{'Linux/gui/src/viewer.rs'}:
            with self.subTest(key=key),self.assertRaises(ValueError):
                sources=dict(self.baseline);sources[key]='e'
                self.verify(sources,[key])

    def test_missing_or_extra_compilation_inputs_are_rejected(self):
        sources=dict(self.baseline);del sources['Linux/native/mod.rs']
        with self.assertRaises(ValueError):self.verify(sources,[])
        sources=dict(self.baseline);sources['Linux/gui/Cargo.toml']='e'
        with self.assertRaises(ValueError):self.verify(sources,['Linux/gui/Cargo.toml'])

    def test_new_rust_module_preserves_dependency_audit_scope(self):
        sources=dict(self.baseline);sources['Linux/gui/src/startup.rs']='e'
        self.assertEqual(self.verify(sources,['Linux/gui/src/startup.rs']),self.baseline)
        for name in ('Linux/gui/src/../build.rs','Linux/gui/src/new.c',
                     'Linux/native/protocol/src/new.rs','Linux/gui/resources/new.css'):
            with self.subTest(name=name),self.assertRaises(ValueError):
                sources=dict(self.baseline);sources[name]='e'
                self.verify(sources,[name])

    def test_omitted_dependency_delta_is_rejected(self):
        sources=dict(self.baseline);sources['Linux/gui/src/viewer.rs']='e';sources['Linux/gui/Cargo.lock']='f'
        with self.assertRaises(ValueError):self.verify(sources,['Linux/gui/src/viewer.rs'])
        with self.assertRaises(ValueError):self.verify(self.baseline,[])


if __name__=='__main__':unittest.main()
