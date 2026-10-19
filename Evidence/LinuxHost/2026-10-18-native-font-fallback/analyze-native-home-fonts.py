#!/usr/bin/env python3
"""Summarize the private warmed font comparison without claiming GPU acceptance."""
import argparse
import hashlib
import json
from pathlib import Path


def analyze(directory):
    inputs = json.loads((directory / 'inputs.json').read_text())
    assert json.loads((directory / 'exit.json').read_text())['returncode'] == 0
    for name, sha in inputs['sources'].items():
        path = directory / 'source' / name
        assert path.resolve().is_relative_to((directory / 'source').resolve())
        assert hashlib.sha256(path.read_bytes()).hexdigest() == sha, name
    result = json.loads((directory / 'run/home-font-result.json').read_text())
    assert result['result'] == 'pass' and result['software_only']
    assert not result['hardware_memory_target_evaluated'] and not result['product_font_changed']
    assert [row['variant'] for row in result['warmups']] == ['baseline', 'subset']
    assert all(row['seconds'] >= 5 for row in result['warmups'])
    records = result['records']
    assert [row['variant'] for row in records] == ['baseline', 'subset', 'subset', 'baseline']
    rows = []
    for index, row in enumerate(records):
        assert len(row['samples']) == 3 and row['samples'][-1]['seconds'] >= 20
        assert all(s['swap_pss_kib'] == 0 for s in row['samples'])
        sample = row['samples'][-1]
        rows.append({'index': index, 'variant': row['variant'],
                     **{key: sample[key] for key in ('pss_kib', 'uss_kib', 'font_pss_kib', 'fd_count')}})
    shapes = json.loads((directory / 'run/font-shapes.json').read_text())
    assert all(case['unknown_glyphs'] == 0 for cases in shapes.values() for case in cases.values())
    assert shapes['baseline']['fallback_regular'] == shapes['subset']['fallback_regular']
    assert shapes['baseline']['fallback_bold'] == shapes['subset']['fallback_bold']
    pairs = []
    for baseline, subset in ((0, 1), (3, 2)):
        pairs.append({'baseline_index': baseline, 'subset_index': subset,
                      **{key + '_reduction': rows[baseline][key] - rows[subset][key]
                         for key in ('pss_kib', 'uss_kib', 'font_pss_kib')}})
    dynamic = None
    if inputs.get('dynamic_text'):
        assert result['widget_observer_enabled']
        assert all(row.get('dynamic_path_completed') for row in result['warmups']), 'Full dynamic path must be warmed'
        dynamic_rows = []
        for index, record in enumerate(records):
            data = record['dynamic']
            assert data['catalog_restored'] and data['editor_buffer_matches']
            assert data['actual_label_missing_glyphs'] == 0
            assert [s['phase'] for s in data['samples']] == ['alias', 'edit', 'returned']
            assert all(s['swap_pss_kib'] == 0 and s['child_count'] == 0 for s in data['samples'])
            dynamic_rows.append({'index': index, 'variant': record['variant'], 'samples': data['samples'],
                                 'alias_font_runs': data['visible_alias_label']['font_runs']})
        differences = []
        for phase_index, phase in enumerate(('alias', 'edit', 'returned')):
            for baseline, subset in ((0, 1), (3, 2)):
                a = dynamic_rows[baseline]['samples'][phase_index]
                b = dynamic_rows[subset]['samples'][phase_index]
                differences.append({'phase': phase, 'baseline_index': baseline, 'subset_index': subset,
                    **{key + '_reduction': a[key] - b[key] for key in ('pss_kib', 'uss_kib', 'font_pss_kib')}})
        dynamic = {'records': dynamic_rows, 'paired_differences': differences,
                   'actual_label_missing_glyphs': 0, 'editor_buffer_matches': True,
                   'diagnostic_observer_loaded_in_gui': True,
                   'editable_layout_not_introspected': True}
    return {'schema': 1, 'measurement': 'private-software-home-fonts',
            'artifact': inputs['artifact'], 'manifest_sha256': inputs['manifest_sha256'],
            'font_probe_sha256': inputs['font_probe_sha256'], 'warmups': result['warmups'],
            'steady_20s': rows, 'paired_differences': pairs,
            'dynamic_text': dynamic,
            'pango_cases': sum(map(len, shapes.values())), 'pango_missing_glyphs': 0,
            'fallback_shaping_preserved': True,
            'pango_sizes': {name: {label: [case['width'], case['height']]
                                 for label, case in cases.items()} for name, cases in shapes.items()},
            'hardware_memory_target_evaluated': False, 'product_font_changed': False,
            'real_desktop_tested': False, 'chinese_input_tested': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    args = parser.parse_args()
    result = analyze(args.run.resolve(strict=True))
    text = json.dumps(result, indent=2) + '\n'
    (args.run / 'analysis.json').write_text(text)
    print(text, end='')


if __name__ == '__main__':
    main()
