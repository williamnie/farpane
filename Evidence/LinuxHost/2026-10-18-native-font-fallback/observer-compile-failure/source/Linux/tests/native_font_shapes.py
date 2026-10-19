"""Shape synthetic UI/fallback text with Pango; never opens a display or input."""
import json
import os
from pathlib import Path
import ctypes as C


def main():
    assert Path('/.dockerenv').is_file() and os.geteuid() != 0
    assert os.environ.get('FARPANE_NATIVE_TEST_MODE') == 'home-fonts'
    assert os.environ.get('HOME') == '/run/farpane-native-test/user'
    # Use the installed public C API; this image has no Python GI bindings.
    pango = C.CDLL('libpango-1.0.so.0')
    cairo = C.CDLL('libpangocairo-1.0.so.0')
    glib = C.CDLL('libglib-2.0.so.0')
    gobject = C.CDLL('libgobject-2.0.so.0')
    for library, symbol, args, result in (
            (cairo, 'pango_cairo_font_map_new', [], C.c_void_p),
            (pango, 'pango_font_map_create_context', [C.c_void_p], C.c_void_p),
            (pango, 'pango_layout_new', [C.c_void_p], C.c_void_p),
            (pango, 'pango_font_description_from_string', [C.c_char_p], C.c_void_p),
            (pango, 'pango_layout_set_font_description', [C.c_void_p, C.c_void_p], None),
            (pango, 'pango_font_description_free', [C.c_void_p], None),
            (pango, 'pango_layout_set_text', [C.c_void_p, C.c_char_p, C.c_int], None),
            (pango, 'pango_layout_get_unknown_glyphs_count', [C.c_void_p], C.c_int),
            (pango, 'pango_layout_get_pixel_size', [C.c_void_p, C.POINTER(C.c_int), C.POINTER(C.c_int)], None),
            (pango, 'pango_layout_serialize', [C.c_void_p, C.c_uint], C.c_void_p),
            (glib, 'g_bytes_get_data', [C.c_void_p, C.POINTER(C.c_size_t)], C.c_void_p),
            (glib, 'g_bytes_unref', [C.c_void_p], None),
            (gobject, 'g_object_unref', [C.c_void_p], None)):
        function = getattr(library, symbol)
        function.argtypes, function.restype = args, result
    probe = json.loads(Path('/fonts/probe.json').read_text())
    fontmap = cairo.pango_cairo_font_map_new()
    context = pango.pango_font_map_create_context(fontmap)
    assert fontmap and context
    texts = {'ui_corpus': ''.join(chr(n) for n in probe['codepoints']),
             'mixed': 'FarPane 设备 ID 123 安全、轻量的远程连接',
             'spacing': '设备 ID 连接\u00a0A 远程\u2003B 电脑\u202fC',
             'fallback': '龘 한 Ω A'}
    records = {}
    for label, text in texts.items():
        for bold in (False, True):
            layout = pango.pango_layout_new(context)
            description = pango.pango_font_description_from_string(
                b'sans-serif Bold 14' if bold else b'sans-serif 14')
            pango.pango_layout_set_font_description(layout, description)
            pango.pango_font_description_free(description)
            pango.pango_layout_set_text(layout, text.encode(), -1)
            unknown = pango.pango_layout_get_unknown_glyphs_count(layout)
            width, height = C.c_int(), C.c_int()
            pango.pango_layout_get_pixel_size(layout, C.byref(width), C.byref(height))
            serialized = pango.pango_layout_serialize(layout, 2)  # PANGO_LAYOUT_SERIALIZE_OUTPUT
            assert serialized
            size = C.c_size_t()
            data = glib.g_bytes_get_data(serialized, C.byref(size))
            shaped = json.loads(C.string_at(data, size.value))
            glib.g_bytes_unref(serialized)
            records[label + ('_bold' if bold else '_regular')] = {
                'unknown_glyphs': unknown, 'width': width.value, 'height': height.value, 'layout': shaped}
            gobject.g_object_unref(layout)
    gobject.g_object_unref(context)
    gobject.g_object_unref(fontmap)
    print(json.dumps(records, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
