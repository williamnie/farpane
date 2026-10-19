#!/usr/bin/env python3
"""Generate renamed CJK/spacing test subsets; never edit system fonts."""
import hashlib
import json
from pathlib import Path
import shutil
import tempfile

import fontTools
from fontTools import subset
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'Build/Linux/native-font-probe'


def main():
    pin = json.loads((ROOT / 'Linux/tests/native-font-probe.lock.json').read_text())
    assert fontTools.__version__ == pin['fonttools']
    sources = sorted((ROOT / 'Linux/gui/src').glob('*.rs'))
    texts = ''.join(path.read_text() for path in sources)
    codepoints = sorted({ord(c) for c in texts if 0x2e80 <= ord(c) <= 0x9fff
                         or 0xff00 <= ord(c) <= 0xffef or 0x20000 <= ord(c) <= 0x2ffff})
    assert codepoints and all(value > 255 for value in codepoints)
    # Pango can keep trailing spaces in a Han run. Its fallback does not split
    # these onto a Latin font, so a CJK-only cmap can produce missing-space
    # glyphs even though per-codepoint fc-match checks pass.
    codepoints = sorted(set(codepoints) | set(pin['spacing_codepoints']))
    output = Path(tempfile.mkdtemp(prefix='fonts.', dir=BUILD))
    (output / 'fonts').mkdir()
    records = []
    for filename, sha in pin['inputs'].items():
        source = BUILD / 'input' / filename
        assert hashlib.sha256(source.read_bytes()).hexdigest() == sha
        font = TTFont(source, fontNumber=pin['face'], recalcTimestamp=False)
        assert font['name'].getDebugName(1) == 'Noto Sans CJK SC'
        assert set(codepoints) <= font.getBestCmap().keys()
        options = subset.Options()
        options.layout_features = ['*']
        options.name_IDs = ['*']
        options.name_languages = ['*']
        options.name_legacy = True
        subsetter = subset.Subsetter(options=options)
        subsetter.populate(unicodes=codepoints)
        subsetter.subset(font)
        style = 'Bold' if 'Bold' in filename else 'Regular'
        family = pin['family']
        postscript = 'FarPaneUIProbe-' + style
        names = {1: family, 2: style, 3: postscript + '-' + sha[:12],
                 4: family + ' ' + style, 6: postscript, 16: family, 17: style}
        font['name'].names = [record for record in font['name'].names if record.nameID not in names]
        for key, value in names.items():
            font['name'].setName(value, key, 3, 1, 0x409)
        cff = font['CFF '].cff
        cff.fontNames = [postscript]
        cff.topDictIndex[0].FamilyName = family
        cff.topDictIndex[0].FullName = family + ' ' + style
        target = output / 'fonts' / (postscript + '.otf')
        font.save(target)
        font.close()
        with TTFont(target) as check:
            assert set(check.getBestCmap()) == set(codepoints)
            assert check['name'].getDebugName(1) == family
        records.append({'file': str(target.relative_to(output)), 'source': filename,
                        'sha256': hashlib.sha256(target.read_bytes()).hexdigest(), 'bytes': target.stat().st_size})
    shutil.copy2(BUILD / 'input/copyright', output / 'copyright')
    (output / 'fonts.conf').write_text('''<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <include ignore_missing="no">/etc/fonts/fonts.conf</include>
  <dir>/fonts/fonts</dir>
  <cachedir>/run/farpane-native-test/user/cache/font-subset</cachedir>
  <match target="pattern">
    <edit name="family" mode="prepend" binding="strong"><string>FarPane UI Probe</string></edit>
  </match>
</fontconfig>
''')
    record = {'pin': pin, 'codepoints': codepoints, 'fonts': records,
              'latin_glyphs_changed': False, 'system_fallback_removed': False,
              'sources': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
              'copyright_sha256': hashlib.sha256((output / 'copyright').read_bytes()).hexdigest()}
    (output / 'probe.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps({'directory': str(output), 'glyphs_per_font': len(codepoints), 'fonts': records}), flush=True)


if __name__ == '__main__':
    main()
