"""External keyboard/screenshot client for a private headless Wayland test only."""
import array
import ctypes as C
import mmap
import os
from pathlib import Path
import socket
import struct
import time
import zlib


class PrivateWayland:
    def __init__(self, path):
        path = Path(path)
        assert Path('/.dockerenv').is_file()
        assert path.parent == Path('/run/farpane-native-test/user') and path.is_socket()
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(4)
        self.socket.connect(str(path))
        self.buffer = b''
        self.next_id = 2
        self.globals = {}
        self.registry = self.new_id()
        self.send(1, 1, self.u32(self.registry))
        self.sync()
        self.seat = self.bind('wl_seat')
        pointer_manager = self.bind('zwlr_virtual_pointer_manager_v1')
        self.pointer = self.new_id()
        self.send(pointer_manager, 0, self.u32(self.seat, self.pointer))
        manager = self.bind('zwp_virtual_keyboard_manager_v1')
        self.keyboard = self.new_id()
        self.send(manager, 0, self.u32(self.seat, self.keyboard))
        self.keys, keymap = self.keymap()
        fd = os.memfd_create('farpane-private-keymap')
        try:
            os.write(fd, keymap)
            self.send(self.keyboard, 0, self.u32(1, len(keymap)), fd)
        finally:
            os.close(fd)
        self.output = self.bind('wl_output')
        self.shm = self.bind('wl_shm')
        self.screencopy = self.bind('zwlr_screencopy_manager_v1')
        self.sync()

    @staticmethod
    def u32(*values):
        return struct.pack('=' + 'I' * len(values), *values)

    def new_id(self):
        value = self.next_id
        self.next_id += 1
        return value

    def send(self, object_id, opcode, payload=b'', fd=None):
        data = self.u32(object_id, ((8 + len(payload)) << 16) | opcode) + payload
        if fd is None:
            self.socket.sendall(data)
        else:
            sent = self.socket.sendmsg([data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [fd]))])
            self.socket.sendall(data[sent:])

    def event(self):
        while True:
            if len(self.buffer) >= 8:
                object_id, header = struct.unpack_from('=II', self.buffer)
                size, opcode = header >> 16, header & 65535
                assert 8 <= size <= 65535
                if len(self.buffer) >= size:
                    body = self.buffer[8:size]
                    self.buffer = self.buffer[size:]
                    if object_id == 1 and opcode == 0:
                        raise AssertionError('Private Wayland protocol error: ' + repr(body))
                    if object_id == self.registry and opcode == 0:
                        name, length = struct.unpack_from('=II', body)
                        interface = body[8:8 + length - 1].decode()
                        self.globals.setdefault(interface, name)
                    return object_id, opcode, body
            data = self.socket.recv(65536)
            assert data, 'Private Wayland connection closed'
            self.buffer += data

    def sync(self):
        callback = self.new_id()
        self.send(1, 0, self.u32(callback))
        while True:
            object_id, opcode, _ = self.event()
            if object_id == callback:
                assert opcode == 0
                return

    def bind(self, interface):
        object_id = self.new_id()
        string = interface.encode() + b'\0'
        payload = self.u32(self.globals[interface], len(string)) + string
        payload += b'\0' * ((-len(string)) % 4) + self.u32(1, object_id)
        self.send(self.registry, 0, payload)
        return object_id

    @staticmethod
    def keymap():
        xkb = C.CDLL('libxkbcommon.so.0')
        class Names(C.Structure):
            _fields_ = [(n, C.c_char_p) for n in ('rules', 'model', 'layout', 'variant', 'options')]
        xkb.xkb_context_new.argtypes = [C.c_int];xkb.xkb_context_new.restype = C.c_void_p
        xkb.xkb_keymap_new_from_names.argtypes = [C.c_void_p, C.POINTER(Names), C.c_int]
        xkb.xkb_keymap_new_from_names.restype = C.c_void_p
        xkb.xkb_keymap_get_as_string.argtypes = [C.c_void_p, C.c_int]
        xkb.xkb_keymap_get_as_string.restype = C.c_void_p
        xkb.xkb_keymap_key_get_syms_by_level.argtypes = [C.c_void_p, C.c_uint, C.c_uint, C.c_uint, C.POINTER(C.POINTER(C.c_uint))]
        xkb.xkb_keymap_key_get_syms_by_level.restype = C.c_int
        xkb.xkb_keymap_unref.argtypes = [C.c_void_p];xkb.xkb_context_unref.argtypes = [C.c_void_p]
        libc = C.CDLL(None);libc.free.argtypes = [C.c_void_p]
        context = xkb.xkb_context_new(0)
        keymap = xkb.xkb_keymap_new_from_names(context, C.byref(Names(None, None, b'us', None, None)), 0)
        assert context and keymap
        pointer = xkb.xkb_keymap_get_as_string(keymap, 1)
        try:
            text = C.string_at(pointer) + b'\0'
            keys = {}
            for code in range(8, 256):
                for level in (0, 1):
                    syms = C.POINTER(C.c_uint)()
                    if xkb.xkb_keymap_key_get_syms_by_level(keymap, code, 0, level, C.byref(syms)) == 1:
                        keys.setdefault(syms[0], (code - 8, level))
            return keys, text
        finally:
            libc.free(pointer);xkb.xkb_keymap_unref(keymap);xkb.xkb_context_unref(context)

    def type(self, text):
        for char in text:
            code, shift = self.keys[ord(char)]
            self.send(self.keyboard, 2, self.u32(shift, 0, 0, 0))
            self.send(self.keyboard, 1, self.u32(int(time.monotonic() * 1000) & 0xffffffff, code, 1))
            self.send(self.keyboard, 1, self.u32(int(time.monotonic() * 1000) & 0xffffffff, code, 0))
        self.send(self.keyboard, 2, self.u32(0, 0, 0, 0))
        self.sync()

    def capture(self, path=None):
        frame = self.new_id()
        self.send(self.screencopy, 0, self.u32(frame, 0, self.output))
        while True:
            object_id, opcode, body = self.event()
            if object_id == frame:
                assert opcode == 0, 'Expected screencopy buffer'
                format_, width, height, stride = struct.unpack('=IIII', body)
                assert format_ in (0, 1) and width == 1020 and height == 720 and stride >= width * 4
                break
        fd = os.memfd_create('farpane-private-screen')
        os.ftruncate(fd, stride * height)
        pool, buffer = self.new_id(), self.new_id()
        try:
            self.send(self.shm, 0, self.u32(pool, stride * height), fd)
            self.send(pool, 0, self.u32(buffer, 0, width, height, stride, format_))
            self.send(frame, 0, self.u32(buffer))
            flags = 0
            while True:
                object_id, opcode, body = self.event()
                if object_id != frame:
                    continue
                if opcode == 1:
                    flags = struct.unpack('=I', body)[0]
                elif opcode == 2:
                    break
                elif opcode == 3:
                    raise AssertionError('Private compositor refused screencopy')
            with mmap.mmap(fd, stride * height, access=mmap.ACCESS_READ) as view:
                raw = bytes(view)
            if flags & 1:
                raw = b''.join(raw[y * stride:(y + 1) * stride] for y in reversed(range(height)))
            if path:
                rows = bytearray()
                for y in range(height):
                    row = raw[y * stride:y * stride + width * 4]
                    rgb = bytearray(width * 3)
                    rgb[0::3], rgb[1::3], rgb[2::3] = row[2::4], row[1::4], row[0::4]
                    rows.append(0);rows.extend(rgb)
                def chunk(kind, data):
                    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
                path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', width, height, 8, 2, 0, 0, 0))
                                 + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))
            return raw, stride
        finally:
            self.send(frame, 1);self.send(buffer, 0);self.send(pool, 1)
            os.close(fd)

    def close(self):
        self.send(self.keyboard, 3)
        self.send(self.pointer, 8)
        self.socket.close()
