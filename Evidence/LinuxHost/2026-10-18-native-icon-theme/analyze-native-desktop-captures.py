#!/usr/bin/env python3
"""Compare private Shell/VKMS PNG pixels; equality does not verify branding."""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageChops


def analyze(directory):
    result = json.loads((directory / 'result.json').read_text())
    assert result['result'] == 'pass' and result['separate_kernel_verified'] is True
    assert result['host_display'] is False and result['network'] == 'none'
    launch = result['guest']['desktop_launch']
    assert launch['shell_observer_enabled'] is True
    comparisons = []
    groups = []
    for method in launch['methods']:
        pair = method.get('capture_comparison')
        if pair is None:
            continue
        name = method['method']
        assert name in ('cli', 'dbus', 'cli-late')
        groups.append((name, [method['capture'], pair['shell'], pair['vkms_after']]))
        cycle = method.get('overview_cycle')
        if cycle:
            assert name == 'cli' and cycle['same_gui_generation'] is True
            assert cycle['icon_lookup_probe_deferred_until_after_cycle_capture'] is True
            groups.append(('cli-reopened', [cycle['capture'], cycle['shell'], cycle['vkms_after']]))
    for name, records in groups:
        expected = [f'launch-{name}.png', f'launch-shell-{name}.png',
                    f'launch-after-shell-{name}.png']
        assert [item['file'] for item in records] == expected
        images = []
        for record in records:
            path = directory / record['file']
            assert path.stat().st_size <= 1024 * 1024
            assert hashlib.sha256(path.read_bytes()).hexdigest() == record['sha256']
            with Image.open(path) as source:
                assert source.format == 'PNG' and 1 <= source.width <= 2560 and 1 <= source.height <= 1600
                images.append(source.convert('RGB'))
        assert all(image.size == images[0].size for image in images)
        row = {'method': name, 'files': expected, 'image_size': images[0].size,
               'vkms_before_fb_id': records[0]['fb_id'], 'vkms_after_fb_id': records[2]['fb_id'],
               'comparisons': []}
        for a, b in ((0, 1), (1, 2), (0, 2)):
            left, right = images[a].tobytes(), images[b].tobytes()
            pixels = sum(left[i:i+3] != right[i:i+3] for i in range(0, len(left), 3))
            row['comparisons'].append({'a': expected[a], 'b': expected[b],
                'changed_pixels': pixels, 'difference_bounds': ImageChops.difference(images[a], images[b]).getbbox(),
                'rgb_equal': left == right})
        comparisons.append(row)
    expected_methods = ['cli', 'dbus', 'cli-late']
    if any(name == 'cli-reopened' for name, _ in groups):
        expected_methods.insert(1, 'cli-reopened')
    assert [row['method'] for row in comparisons] == expected_methods
    return {'all_rgb_pairs_equal': all(pair['rgb_equal'] for row in comparisons for pair in row['comparisons']),
            'icon_correctness_evaluated': False, 'product_acceptance': False,
            'scope': 'bounded private Shell/VKMS triples; optional same-window overview cycle',
            'comparisons': comparisons}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    print(json.dumps(analyze(parser.parse_args().directory.resolve(strict=True)), indent=2))
