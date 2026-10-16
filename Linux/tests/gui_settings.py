"""Navigate only the isolated Xvfb test display; never run against a host display."""
import ctypes
import os
from pathlib import Path
import subprocess
import time

if os.environ.get('DISPLAY') != ':99' or not Path('/.dockerenv').exists() or not Path('/evidence').is_dir():
    raise SystemExit('This helper is restricted to the isolated GUI test container')
x11 = ctypes.CDLL('libX11.so.6')
xtest = ctypes.CDLL('libXtst.so.6')
x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XFlush.argtypes = [ctypes.c_void_p]
x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
xtest.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
xtest.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
display = x11.XOpenDisplay(b':99')
if not display:
    raise SystemExit('Xvfb is not ready')


def button(number):
    xtest.XTestFakeButtonEvent(display, number, 1, 0)
    xtest.XTestFakeButtonEvent(display, number, 0, 0)
    x11.XFlush(display)


def screenshot(name):
    subprocess.run(['xwd', '-root', '-silent', '-out', '/evidence/' + name + '.xwd'], check=True)


try:
    xtest.XTestFakeMotionEvent(display, 0, 816, 99, 0)
    button(1)
    time.sleep(3)
    screenshot('settings-top')
    xtest.XTestFakeMotionEvent(display, 0, 750, 500, 0)
    for _ in range(5):
        button(5)
        time.sleep(0.1)
    time.sleep(1)
    screenshot('settings-gpu')
finally:
    x11.XCloseDisplay(display)
