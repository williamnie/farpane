"""Shape synthetic UI/fallback text with Pango; never opens a display or input."""
import json
import os
from pathlib import Path

import gi
gi.require_version('Pango', '1.0')
gi.require_version('PangoCairo', '1.0')
from gi.repository import Pango, PangoCairo


def main():
    assert Path('/.dockerenv').is_file() and os.geteuid() != 0
    assert os.environ.get('FARPANE_NATIVE_TEST_MODE') == 'home-fonts'
    assert os.environ.get('HOME') == '/run/farpane-native-test/user'
    probe = json.loads(Path('/fonts/probe.json').read_text())
    fontmap = PangoCairo.FontMap.new()
    context = fontmap.create_context()
    texts = {'ui_corpus': ''.join(chr(n) for n in probe['codepoints']),
             'mixed': 'FarPane 设备 ID 123 安全、轻量的远程连接',
             'fallback': '龘 한 Ω A'}
    records = {}
    for label, text in texts.items():
        for bold in (False, True):
            layout = Pango.Layout.new(context)
            layout.set_font_description(Pango.FontDescription.from_string(
                'sans-serif Bold 14' if bold else 'sans-serif 14'))
            layout.set_text(text, -1)
            assert layout.get_unknown_glyphs_count() == 0, (label, bold)
            runs = []
            iterator = layout.get_iter()
            while True:
                run = iterator.get_run_readonly()
                if run:
                    item = run.item
                    runs.append({'text': text.encode()[item.offset:item.offset + item.length].decode(),
                                 'font': item.analysis.font.describe().to_string()})
                if not iterator.next_run():
                    break
            width, height = layout.get_pixel_size()
            records[label + ('_bold' if bold else '_regular')] = {
                'unknown_glyphs': 0, 'width': width, 'height': height, 'runs': runs}
    print(json.dumps(records, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
