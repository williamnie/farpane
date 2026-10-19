import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('gui_layer',
    Path(__file__).resolve().parents[2] / 'Scripts/linux/repackage-native-gui-layer.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FrozenCoreBoundary(unittest.TestCase):
    def setUp(self):
        self.sources = {'Linux/gui/src/app.rs': 'old', 'Linux/gui/Cargo.lock': 'lock',
                        'Linux/gui/src/gpu_renderer.c': 'bridge',
                        'Linux/native/protocol/src/lib.rs': 'protocol',
                        'Linux/native/mod.rs': 'core'}
        self.gui = {k: v for k, v in self.sources.items() if k != 'Linux/native/mod.rs'}
        self.gui['Linux/gui/src/app.rs'] = 'new'

    def test_core_candidate_can_use_matching_gui_compilation_inputs(self):
        self.assertEqual(module.gui_delta(self.sources, self.gui), ['Linux/gui/src/app.rs'])

    def test_protocol_dependency_and_bridge_drift_rejected(self):
        for key in ['Linux/gui/Cargo.lock', 'Linux/gui/src/gpu_renderer.c',
                    'Linux/native/protocol/src/lib.rs']:
            with self.subTest(key=key), self.assertRaises(ValueError):
                changed = dict(self.gui); changed[key] = 'changed'
                module.gui_delta(self.sources, changed)

    def test_existing_stylesheet_may_change(self):
        self.sources['Linux/gui/resources/style.css'] = 'old'
        self.gui['Linux/gui/resources/style.css'] = 'new'
        self.assertEqual(module.gui_delta(self.sources, self.gui),
                         ['Linux/gui/resources/style.css', 'Linux/gui/src/app.rs'])

    def test_other_resources_rejected(self):
        for key in ['Linux/gui/resources/farpane.gresource.xml',
                    'Linux/gui/resources/org.farpane.FarPane.svg']:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.sources[key] = 'old'
                changed = dict(self.gui); changed[key] = 'new'
                module.gui_delta(self.sources, changed)

    def test_layers_stack_with_history(self):
        self.assertEqual(module.layer_slot({}), ([], 'gui-layer'))
        first = {'version': '1'}
        self.assertEqual(module.layer_slot({'gui_layer': first}), ([first], 'gui-layer-2'))
        second = {'version': '2'}
        self.assertEqual(module.layer_slot({'gui_layer': second, 'gui_layer_history': [first]}),
                         ([first, second], 'gui-layer-3'))
        with self.assertRaises(ValueError):
            module.layer_slot({'gui_layer_history': [first]})

    def test_added_and_missing_inputs_rejected(self):
        for operation in ['add', 'remove']:
            with self.subTest(operation=operation), self.assertRaises(ValueError):
                changed = dict(self.gui)
                if operation == 'add':
                    changed['Linux/gui/src/new.rs'] = 'unexpected'
                else:
                    del changed['Linux/gui/Cargo.lock']
                module.gui_delta(self.sources, changed)


if __name__ == '__main__':
    unittest.main()
