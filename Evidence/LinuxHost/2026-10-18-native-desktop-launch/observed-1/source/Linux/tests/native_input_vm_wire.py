"""Mac-style literal Seq over real RustDesk TCP, only in the guarded input VM.

This minimal test peer authenticates normally. It never replaces Host dispatch,
clipboard code, privileged IPC or kernel input. It is not a Mac GUI/IME test.
Field numbers and frame lengths follow the pinned base/message.proto and
hbb_common/bytes_codec.rs; default Seq flags match ui_session_interface.rs.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import struct
import time

from native_input_vm_desktop import OUTPUT, require_guest, wait

MAX_PACKET=16*1024*1024


def varint(value):
    assert 0<=value<2**64
    out=bytearray()
    while value>=128:out.append((value&127)|128);value>>=7
    out.append(value)
    return bytes(out)


def number(tag,value):return varint(tag<<3)+varint(value)


def blob(tag,value):
    if isinstance(value,str):value=value.encode()
    return varint((tag<<3)|2)+varint(len(value))+value


def decode(data):
    """Bounded protobuf fields needed for handshake/notifications only."""
    result={};offset=0
    def integer():
        nonlocal offset
        value=0
        for shift in range(0,70,7):
            assert offset<len(data),'Truncated protobuf varint'
            byte=data[offset];offset+=1
            value|=(byte&127)<<shift
            if byte<128:
                assert value<2**64
                return value
        raise ValueError('Oversized protobuf varint')
    while offset<len(data):
        tag=integer();field=tag>>3;wire=tag&7;assert field>0
        if wire==0:value=integer()
        elif wire in (1,2,5):
            size=integer() if wire==2 else (8 if wire==1 else 4)
            assert size<=len(data)-offset,'Truncated protobuf field'
            value=data[offset:offset+size];offset+=size
        else:raise ValueError('Unexpected protobuf wire type')
        result[field]=value
    return result


def frame(data):
    assert len(data)<=MAX_PACKET
    size=next(n for n in range(1,5) if len(data)<2**(8*n-2))
    return ((len(data)<<2)|(size-1)).to_bytes(size,'little')+data


def seq_message(text):
    # Exactly KeyEvent::new(); set_seq(text); Message::set_key_event(...).
    # No down, press, mode, modifiers or separate clipboard packet.
    return blob(15,blob(6,text))


class Peer:
    def __init__(self,report):
        require_guest()  # BEFORE any network connection
        assert json.loads(Path('/.farpane-input-vm').read_text())['input_driver']=='wire'
        self.report=report;self.buffer=bytearray();self.hash=None;self.login=None
        self.conn=socket.create_connection(('127.0.0.1',21118),timeout=3)
        self.conn.setblocking(False)
        self.send(b'')  # Same direct-IP, unpinned peer handshake as upstream.

    def send(self,data):
        assert len(data)<=MAX_PACKET
        # Messages are tiny; still bound a temporarily full send queue.
        remaining=memoryview(frame(data));deadline=time.monotonic()+2
        while remaining:
            assert time.monotonic()<deadline,'Private peer send timed out'
            if not select.select([], [self.conn], [], .05)[1]:continue
            try:sent=self.conn.send(remaining)
            except BlockingIOError:continue
            assert sent>0
            remaining=remaining[sent:]

    def pump(self):
        while select.select([self.conn],[],[],0)[0]:
            chunk=self.conn.recv(65536);assert chunk,'Private peer was closed'
            self.buffer.extend(chunk);assert len(self.buffer)<=MAX_PACKET+4
            while self.buffer:
                head=(self.buffer[0]&3)+1
                if len(self.buffer)<head:break
                size=int.from_bytes(self.buffer[:head],'little')>>2
                assert size<=MAX_PACKET
                if len(self.buffer)<head+size:break
                data=bytes(self.buffer[head:head+size]);del self.buffer[:head+size]
                self.handle(decode(data))

    def handle(self,message):
        if 9 in message:self.hash=decode(message[9])
        if 8 in message:self.login=decode(message[8])
        if 6 in message:
            self.report['video_packets']+=1
            self.send(blob(19,number(12,1)))
        if 5 in message:
            delay=decode(message[5])
            if not delay.get(2,0):self.send(blob(5,message[5]))
        if 19 in message:
            misc=decode(message[19])
            assert 9 not in misc,'Peer closed: '+misc.get(9,b'').decode(errors='replace')
        if 21 in message:self.report['message_boxes']+=1

    def login_with(self,password):
        assert self.hash and 1 in self.hash and 2 in self.hash
        salted=hashlib.sha256(password.encode()+self.hash[1]).digest()
        challenge=hashlib.sha256(salted+self.hash[2]).digest()
        options=(number(2,1)+number(4,1)+number(5,1)+number(7,2)+number(8,2)
                 +number(9,1)+blob(10,number(1,1))+number(11,5)+number(12,1))
        login=(blob(1,'127.0.0.1')+blob(2,challenge)+blob(4,'private-mac-seq-fixture')
               +blob(5,'Private Mac Seq fixture')+blob(6,options)+number(10,1)
               +blob(11,'1.5.0')+blob(13,'Mac OS'))
        self.login=None;self.send(blob(7,login))

    def key(self,code,down,modifiers=()):
        self.send(blob(15,(number(1,1) if down else b'')+number(3,code)
                       +(blob(8,b''.join(varint(m) for m in modifiers)) if modifiers else b'')))


def exercise(core,env,account,device):
    require_guest()
    assert os.geteuid()==0
    marker=json.loads(Path('/.farpane-input-vm').read_text())
    assert marker['input_driver']=='wire'
    report={'result':'fail','transport':'private-direct-TCP-protocol-peer',
            'seq_flags':{'down':False,'press':False,'mode':'Legacy','modifiers':[]},
            'target':marker['target'],'video_packets':0,'message_boxes':0,'cases':[],
            'events':[],'host_input_exposed':False,'mac_gui_tested':False}
    peer=None
    fd=os.open(device,os.O_RDONLY|os.O_NONBLOCK|os.O_CLOEXEC)  # never grab
    def drain():
        size=struct.calcsize('llHHi')
        while True:
            try:data=os.read(fd,65536)
            except BlockingIOError:break
            assert len(data)%size==0
            report['events'].extend(list(struct.unpack('llHHi',data[i:i+size])[2:])
                                    for i in range(0,len(data),size))
        assert [0,3,0] not in report['events'],'Observer lost kernel events'
    def pump():
        peer.pump();drain()
    def until(predicate,message,seconds=5):
        def check():pump();return predicate()
        return wait(check,message,seconds)
    def pause(seconds):
        end=time.monotonic()+seconds
        while time.monotonic()<end:pump();time.sleep(.02)
    def state():return json.loads((OUTPUT/'entry.json').read_text())
    def held(code):
        # Kernel EVIOCGKEY from the same evdev endpoint as GNOME, not a mock.
        bits=bytearray(96);fcntl.ioctl(fd,0x80604518,bits,True)
        return bool(bits[code//8]&(1<<(code%8)))
    try:
        def connect():
            nonlocal peer
            try:peer=Peer(report);return True
            except ConnectionRefusedError:return False
        wait(connect,'Private Host direct listener did not start')
        until(lambda:peer.hash,'Private peer did not receive Hash')
        peer.login_with('incorrect-smoke-password')
        until(lambda:peer.login,'Private peer did not receive login rejection')
        assert peer.login.get(1),peer.login
        report['incorrect_password_rejected']=True
        peer.login_with('native-viewer-smoke')
        until(lambda:peer.login,'Private peer did not authenticate')
        assert 2 in peer.login and 1 not in peer.login,peer.login
        info=decode(peer.login[2]);assert info[3]==b'Linux',info
        report['authenticated']=True
        until(lambda:report['video_packets']>0,'Authenticated peer received no video',15)
        display=decode(info[4])
        assert display.get(1,0)==0 and display.get(2,0)==0
        x,y=display[3]//2,display[4]//2
        # Match the GTK test's remote canvas click to leave GNOME overview.
        # These are real product MouseEvents, confined to the guest display.
        for mask in (0,9,10):
            peer.send(blob(10,number(1,mask)+number(2,x*2)+number(3,y*2)))
            pause(.1)
        peer.key(1,True);pause(.08);peer.key(31,True,(1,));pause(.08)
        peer.key(31,False,(1,));peer.key(1,False)
        until(lambda:state()['active'] and state()['focused'],'Private target did not receive focus')
        assert state()['text']==''
        expected=''
        for label,text,hold_control in [('whole-seq','中文测试',False),
                                         ('held-control','控制提交',True),
                                         ('mixed-after-release','混合A1，🙂é',False)]:
            case={'name':label,'text':text,'held_control':hold_control,'before':state(),
                  'event_start':len(report['events'])}
            report['cases'].append(case)
            if hold_control:
                peer.key(4,True)
                until(lambda:held(29),'Control did not become held in the guest kernel')
                case['control_confirmed_before']=True
            payload=seq_message(text);case['message_hex']=payload.hex()
            peer.send(payload)
            expected+=text
            def arrived():
                case['after']=state();case['control_after']=held(29)
                return case['after']['text']==expected
            until(arrived,'Mac-style '+label+' did not reach the target',3)
            pause(.25)
            assert arrived(),'Duplicate or altered text after committed Seq'
            assert case['after']['active'] and case['after']['focused']
            assert not held(29),'Literal Seq left Control pressed'
            case['events']=report['events'][case['event_start']:]
            keys=[e for e in case['events'] if e[0]==1]
            paste=[[1,42,1],[1,110,1],[1,110,0],[1,42,0]]
            assert sum(keys[i:i+4]==paste for i in range(len(keys)-3))==1,keys
            if hold_control:
                assert keys.index([1,29,0])<keys.index([1,42,1]),keys
                # The client's delayed physical key-up must be harmless.
                peer.key(4,False);pause(.1);assert state()['text']==expected
            case['result']='pass'
        report['result']='pass'
        return report
    finally:
        drain();os.close(fd)
        if peer is not None:peer.conn.close()
        for case in report['cases']:
            if 'events' not in case:case['events']=report['events'][case['event_start']:]
        (OUTPUT/'network-input.json').write_text(json.dumps(report,ensure_ascii=False))
