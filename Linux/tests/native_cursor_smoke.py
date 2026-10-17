"""Exercise actual remote cursor colors/hotspots on two private Xvfb servers."""
import ctypes as c
import json
from pathlib import Path
import time


def exercise_cursor(directory):
    assert Path('/.dockerenv').exists()
    x=c.CDLL('libX11.so.6');fix=c.CDLL('libXfixes.so.3');xtst=c.CDLL('libXtst.so.6');xc=c.CDLL('libXcursor.so.1')
    class Color(c.Structure):
        _fields_=[('pixel',c.c_ulong),('red',c.c_ushort),('green',c.c_ushort),('blue',c.c_ushort),('flags',c.c_char),('pad',c.c_char)]
    class Image(c.Structure):
        _fields_=[('x',c.c_short),('y',c.c_short),('width',c.c_ushort),('height',c.c_ushort),('xhot',c.c_ushort),('yhot',c.c_ushort),('serial',c.c_ulong),('pixels',c.POINTER(c.c_ulong))]
    class CursorImage(c.Structure):
        _fields_=[('version',c.c_uint),('size',c.c_uint),('width',c.c_uint),('height',c.c_uint),('xhot',c.c_uint),('yhot',c.c_uint),('delay',c.c_uint),('pixels',c.POINTER(c.c_uint32))]
    xc.XcursorImageCreate.argtypes=[c.c_int,c.c_int];xc.XcursorImageCreate.restype=c.POINTER(CursorImage)
    xc.XcursorImageLoadCursor.argtypes=[c.c_void_p,c.POINTER(CursorImage)];xc.XcursorImageLoadCursor.restype=c.c_ulong
    xc.XcursorImageDestroy.argtypes=[c.POINTER(CursorImage)]
    x.XOpenDisplay.argtypes=[c.c_char_p];x.XOpenDisplay.restype=c.c_void_p
    x.XDefaultRootWindow.argtypes=[c.c_void_p];x.XDefaultRootWindow.restype=c.c_ulong
    x.XCreateBitmapFromData.argtypes=[c.c_void_p,c.c_ulong,c.c_char_p,c.c_uint,c.c_uint];x.XCreateBitmapFromData.restype=c.c_ulong
    x.XCreatePixmapCursor.argtypes=[c.c_void_p,c.c_ulong,c.c_ulong,c.POINTER(Color),c.POINTER(Color),c.c_uint,c.c_uint];x.XCreatePixmapCursor.restype=c.c_ulong
    x.XDefineCursor.argtypes=[c.c_void_p,c.c_ulong,c.c_ulong]
    x.XFreePixmap.argtypes=[c.c_void_p,c.c_ulong];x.XFreeCursor.argtypes=[c.c_void_p,c.c_ulong]
    x.XFlush.argtypes=[c.c_void_p];x.XFree.argtypes=[c.c_void_p];x.XCloseDisplay.argtypes=[c.c_void_p]
    x.XQueryTree.argtypes=[c.c_void_p,c.c_ulong,c.POINTER(c.c_ulong),c.POINTER(c.c_ulong),c.POINTER(c.POINTER(c.c_ulong)),c.POINTER(c.c_uint)]
    fix.XFixesGetCursorImage.argtypes=[c.c_void_p];fix.XFixesGetCursorImage.restype=c.POINTER(Image)
    xtst.XTestFakeMotionEvent.argtypes=[c.c_void_p,c.c_int,c.c_int,c.c_int,c.c_ulong]
    host=x.XOpenDisplay(b':91');gui=x.XOpenDisplay(b':92');assert host and gui
    root=x.XDefaultRootWindow(host);cursors=[]
    def windows(window):
        values=[window];r=c.c_ulong();parent=c.c_ulong();children=c.POINTER(c.c_ulong)();count=c.c_uint()
        assert x.XQueryTree(host,window,c.byref(r),c.byref(parent),c.byref(children),c.byref(count))
        try:
            for i in range(count.value):values+=windows(children[i])
        finally:
            if children:x.XFree(children)
        return values
    def create(red,green,hot):
        bits=(b'\xff\xff\0\0')*32;mask=b'\xff'*128
        a=x.XCreateBitmapFromData(host,root,bits,32,32);b=x.XCreateBitmapFromData(host,root,mask,32,32)
        assert a and b
        foreground=Color(0,red,green,0,b'\7',b'\0');background=Color(0,0,0,65535,b'\7',b'\0')
        cursor=x.XCreatePixmapCursor(host,a,b,c.byref(foreground),c.byref(background),*hot)
        x.XFreePixmap(host,a);x.XFreePixmap(host,b);assert cursor;cursors.append(cursor);return cursor
    def apply(cursor):
        for window in windows(root):x.XDefineCursor(host,window,cursor)
        x.XFlush(host)
    def translucent():
        image=xc.XcursorImageCreate(32,32);assert image
        try:
            image.contents.xhot=5;image.contents.yhot=7
            for i in range(32*32):image.contents.pixels[i]=0x80800000 if i%32<16 else 0xff0000ff
            cursor=xc.XcursorImageLoadCursor(host,image);assert cursor;cursors.append(cursor);return cursor
        finally:xc.XcursorImageDestroy(image)
    def sample():
        pointer=fix.XFixesGetCursorImage(gui);assert pointer
        try:
            value=pointer.contents
            return {'width':value.width,'height':value.height,'hotspot':[value.xhot,value.yhot],
                    'first':int(value.pixels[0])&0xffffffff,
                    'last':int(value.pixels[value.width-1])&0xffffffff}
        finally:x.XFree(pointer)
    def expect(color,hot):
        deadline=time.monotonic()+2
        while True:
            value=sample()
            if value=={'width':32,'height':32,'hotspot':list(hot),'first':color,'last':0xff0000ff}:return value
            assert time.monotonic()<deadline, f'Remote cursor did not reach native X cursor: {value}'
            time.sleep(.03)
    try:
        # Mouse stays on the actual remote canvas, not on GTK's toolbar.
        xtst.XTestFakeMotionEvent(gui,-1,510,380,0);x.XFlush(gui);time.sleep(.2)
        first=create(65535,0,(5,7));second=create(0,65535,(9,11))
        apply(first);a=expect(0xffff0000,(5,7))
        apply(second);b=expect(0xff00ff00,(9,11))
        apply(first);again=expect(0xffff0000,(5,7))
        apply(translucent());alpha=expect(0x80800000,(5,7))
        # Local toolbar uses its own pointer; remote shape must not leak there.
        xtst.XTestFakeMotionEvent(gui,-1,510,40,0);x.XFlush(gui);time.sleep(.2)
        assert sample()!=alpha,'Remote cursor leaked into local header'
        (directory/'cursor-result.json').write_text(json.dumps({'first':a,'second':b,'cached_reselection':again,'alpha_preserved':alpha,'toolbar_kept_local':True},indent=2))
    finally:
        for cursor in cursors:x.XFreeCursor(host,cursor)
        x.XCloseDisplay(host);x.XCloseDisplay(gui)
