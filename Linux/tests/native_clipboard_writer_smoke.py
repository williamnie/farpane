#!/usr/bin/env python3
"""Exercise the native X11 provider on an owned Xvfb with synthetic PNGs only."""
from pathlib import Path
import hashlib
import json
import os
import struct
import subprocess
import time
import zlib


def digest(path):
    value=hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):value.update(chunk)
    return value.hexdigest()


def chunk(kind,data):
    return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)


def synthetic_png(path,size=None):
    # Real two-pixel image plus valid private ancillary padding. The maximum
    # payload tests transport bytes, not a claim about maximum decoded pixels.
    header=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',2,1,8,6,0,0,0))
    image=chunk(b'IDAT',zlib.compress(b'\0\x01\x02\x03\0\x09\x08\x07\xff'))
    end=chunk(b'IEND',b'')
    with path.open('wb') as stream:
        stream.write(header);stream.write(image)
        if size is not None:
            length=size-len(header)-len(image)-len(end)-12
            assert length>0
            stream.write(struct.pack('!I',length)+b'fpAD');crc=zlib.crc32(b'fpAD')
            block=b'x'*(1024*1024)
            while length:
                data=block[:min(length,len(block))];stream.write(data);crc=zlib.crc32(data,crc);length-=len(data)
            stream.write(struct.pack('!I',crc&0xffffffff))
        stream.write(end)
    if size is not None:assert path.stat().st_size==size


def rgba_pixels(path):
    value=path.read_bytes();assert value[:8]==b'\x89PNG\r\n\x1a\n'
    offset=8;compressed=b'';width=height=None
    while offset<len(value):
        size=struct.unpack('!I',value[offset:offset+4])[0];kind=value[offset+4:offset+8];data=value[offset+8:offset+8+size]
        assert struct.unpack('!I',value[offset+8+size:offset+12+size])[0]==zlib.crc32(kind+data)&0xffffffff
        if kind==b'IHDR':
            width,height,depth,color,compression,filter_,interlace=struct.unpack('!IIBBBBB',data)
            assert (width,height,depth,color,compression,filter_,interlace)==(2,1,8,6,0,0,0)
        if kind==b'IDAT':compressed+=data
        offset+=12+size
    raw=zlib.decompress(compressed);assert len(raw)==9
    decoded=bytearray(8);kind=raw[0]
    for i,x in enumerate(raw[1:]):
        left=decoded[i-4] if i>=4 else 0
        # Only one row: upper and upper-left are both zero.
        predicted={0:0,1:left,2:0,3:left//2,4:left}[kind]
        decoded[i]=(x+predicted)&255
    return bytes(decoded)


def main():
    assert Path('/.dockerenv').is_file()
    assert not os.environ.get('DISPLAY') and not os.environ.get('WAYLAND_DISPLAY')
    assert not Path('/tmp/.X11-unix/X91').exists()
    root=Path('/workspace/Build/Linux/clipboard-writer-smoke')/time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())
    root.mkdir(parents=True);print(root,flush=True)
    for name,size in [('small.png',None),('medium.png',2*1024*1024),('max.png',128*1024*1024)]:synthetic_png(root/name,size)
    subprocess.run(['cc','-std=c11','-D_POSIX_C_SOURCE=200809L','-Wall','-Wextra','-Werror',
        '/workspace/Linux/tests/x11_clipboard_fixture.c','-lX11','-o',str(root/'clipboard-fixture')],check=True)
    runtime=root/'runtime';runtime.mkdir(mode=0o700)
    env=dict(os.environ,DISPLAY=':91',XDG_RUNTIME_DIR=str(runtime),XDG_CONFIG_HOME=str(runtime/'config'),
        XDG_CACHE_HOME=str(runtime/'cache'),XDG_DATA_HOME=str(runtime/'data'),FARPANE_PRIVATE_CLIPBOARD_WRITER_TEST=str(root),
        CARGO_TARGET_DIR='/workspace/Build/Linux/target',VCPKG_ROOT='/workspace/Build/Linux/vcpkg',CXXFLAGS='-include cstdint')
    with (root/'xvfb.log').open('w') as log:server=subprocess.Popen(['Xvfb',':91','-screen','0','320x200x24','-nolisten','tcp'],env=env,stdout=log,stderr=log)
    try:
        until=time.monotonic()+3
        while not Path('/tmp/.X11-unix/X91').exists():
            assert server.poll() is None and time.monotonic()<until;time.sleep(.03)
        with (root/'cargo-test.log').open('w') as log:
            subprocess.run(['cargo','test','--offline','--locked','--no-default-features','--features','farpane-native,linux-gpu-media',
                '--lib','farpane_native::clipboard_x11_writer::tests::private_x11_large_selection_lifecycle','--','--exact','--ignored'],
                cwd='/workspace/Build/Linux/src/rustdesk',env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
        assert digest(root/'max.png')==digest(root/'max-result.png')
        assert digest(root/'small.png')==digest(root/'after-timeout.png')
        assert digest(root/'medium.png')==digest(root/'lost-owner-result.png')
        assert rgba_pixels(root/'rgba-result.png')==b'\x01\x02\x03\0\x09\x08\x07\xff'
        report=json.loads((root/'writer-result.json').read_text())
        report['sha256']={name:{'bytes':(root/name).stat().st_size,'sha256':digest(root/name)} for name in
            ['max.png','max-result.png','small.png','after-timeout.png','rgba-result.png','medium.png','lost-owner-result.png']}
        pss={}
        for name in ['before','retained','after-transfer']:
            data=(root/f'{name}-smaps.txt').read_text()
            pss[name]=int(next(line.split()[1] for line in data.splitlines() if line.startswith('Pss:')))
        assert pss['retained']-pss['before']<128*1024+16*1024,pss
        assert pss['after-transfer']-pss['before']<128*1024+16*1024,pss
        report['pss_kib']=pss
        report['checks']+=['full_payload_sha256','rgba_alpha_pixel_decode','bounded_provider_pss']
        (root/'result.json').write_text(json.dumps(report,indent=2));print(json.dumps(report),flush=True)
    finally:
        if server.poll() is None:server.terminate();server.wait(timeout=3)


if __name__=='__main__':main()
