"""Reject a GUI source archive derived from a different core or dependency baseline."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('gui_source',Path(__file__).resolve().parents[2]/'Scripts/linux/package-native-gui-source.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)


class GuiSourceBoundary(unittest.TestCase):
    def setUp(self):
        self.parent={'sources':{'Linux/gui/src/viewer.rs':'a','Linux/gui/Cargo.lock':'b','Linux/native/mod.rs':'c'},
            'binaries':{'native-core':'core-old','native-gui':'gui-old'},
            'components':{'native-core':{'protocol':1},'native-gui':{'protocol':1}},
            'core_features':['farpane-native','linux-gpu-media']}
        receipt=copy.deepcopy(self.parent);receipt['sources']['Linux/gui/src/viewer.rs']='d';receipt['binaries']['native-gui']='gui-new'
        self.build={'build_receipt':receipt,'gui_update':{'schema':1,'core_rebuilt':False,
            'media_rebuilt':False,'changed_sources':['Linux/gui/src/viewer.rs']}}

    def test_existing_gui_rust_delta_is_accepted(self):
        self.assertEqual(module.validate_delta(self.parent,self.build),['Linux/gui/src/viewer.rs'])

    def test_new_gui_rust_module_is_included_in_the_exact_delta(self):
        changed=copy.deepcopy(self.build)
        changed['build_receipt']['sources']['Linux/gui/src/startup.rs']='e'
        paths=['Linux/gui/src/startup.rs','Linux/gui/src/viewer.rs']
        changed['gui_update']['changed_sources']=paths
        self.assertEqual(module.validate_delta(self.parent,changed),paths)
        del changed['build_receipt']['sources']['Linux/gui/Cargo.lock']
        with self.assertRaises(ValueError):module.validate_delta(self.parent,changed)

    def test_changed_core_or_dependency_source_is_rejected(self):
        for key in ('Linux/gui/Cargo.lock','Linux/native/mod.rs'):
            with self.subTest(key=key),self.assertRaises(ValueError):
                changed=copy.deepcopy(self.build);changed['build_receipt']['sources'][key]='x'
                module.validate_delta(self.parent,changed)

    def test_wrong_core_binary_protocol_or_features_is_rejected(self):
        for key,value in (('binaries',{'native-core':'different','native-gui':'gui-new'}),
                          ('components',{}),('core_features',[])):
            with self.subTest(key=key),self.assertRaises(ValueError):
                changed=copy.deepcopy(self.build);changed['build_receipt'][key]=value
                module.validate_delta(self.parent,changed)

    def test_undeclared_gui_delta_is_rejected(self):
        self.build['gui_update']['changed_sources']=[]
        with self.assertRaises(ValueError):module.validate_delta(self.parent,self.build)


if __name__=='__main__':unittest.main()
