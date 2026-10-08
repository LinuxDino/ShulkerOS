"""Tiny XTEST driver (ctypes, no python-xlib): keys, typing, mouse clicks, screenshots.

    from xinput import X
    x = X(":99")
    x.type("uname -a\n"); x.key("Escape"); x.click(640, 360, button=3); x.screenshot("a.png")
"""
import ctypes
import ctypes.util
import subprocess
import time

xlib = ctypes.cdll.LoadLibrary(ctypes.util.find_library("X11"))
xtst = ctypes.cdll.LoadLibrary(ctypes.util.find_library("Xtst"))
xlib.XOpenDisplay.restype = ctypes.c_void_p
xlib.XOpenDisplay.argtypes = [ctypes.c_char_p]
xlib.XStringToKeysym.restype = ctypes.c_ulong
xlib.XStringToKeysym.argtypes = [ctypes.c_char_p]
xlib.XKeysymToKeycode.restype = ctypes.c_ubyte
xlib.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
xlib.XFlush.argtypes = [ctypes.c_void_p]
xtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
xtst.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
xtst.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]

NAMES = {" ": "space", "\n": "Return", "\t": "Tab", "-": "minus", "=": "equal", "[": "bracketleft",
         "]": "bracketright", ";": "semicolon", "'": "apostrophe", ",": "comma", ".": "period",
         "/": "slash", "\\": "backslash", "`": "grave"}
SHIFTED = {"!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
           ")": "0", "_": "minus", "+": "equal", "{": "bracketleft", "}": "bracketright", ":": "semicolon",
           '"': "apostrophe", "<": "comma", ">": "period", "?": "slash", "|": "backslash", "~": "grave"}


class X:
    def __init__(self, display=":99", delay=0.03):
        self.display = display
        self.d = xlib.XOpenDisplay(display.encode())
        if not self.d:
            raise RuntimeError("cannot open display " + display)
        self.delay = delay

    def code(self, name):
        ks = xlib.XStringToKeysym(name.encode())
        if not ks:
            raise ValueError("unknown key " + name)
        return xlib.XKeysymToKeycode(self.d, ks)

    def _key(self, code, down):
        xtst.XTestFakeKeyEvent(self.d, code, 1 if down else 0, 0)
        xlib.XFlush(self.d)

    def key(self, name, shift=False, ctrl=False):
        mods = ([self.code("Shift_L")] if shift else []) + ([self.code("Control_L")] if ctrl else [])
        for m in mods:
            self._key(m, True)
        c = self.code(name)
        self._key(c, True)
        time.sleep(self.delay)
        self._key(c, False)
        for m in reversed(mods):
            self._key(m, False)
        time.sleep(self.delay)

    def type(self, text):
        for ch in text:
            if ch in SHIFTED:
                self.key(SHIFTED[ch], shift=True)
            elif ch.isupper():
                self.key(ch.lower(), shift=True)
            else:
                self.key(NAMES.get(ch, ch))

    def move(self, x, y):
        xtst.XTestFakeMotionEvent(self.d, -1, x, y, 0)
        xlib.XFlush(self.d)
        time.sleep(self.delay)

    def click(self, x=None, y=None, button=1):
        if x is not None:
            self.move(x, y)
        xtst.XTestFakeButtonEvent(self.d, button, 1, 0)
        xlib.XFlush(self.d)
        time.sleep(0.08)
        xtst.XTestFakeButtonEvent(self.d, button, 0, 0)
        xlib.XFlush(self.d)
        time.sleep(self.delay)

    def screenshot(self, path):
        subprocess.run(["import", "-display", self.display, "-window", "root", path], check=True)
        return path
