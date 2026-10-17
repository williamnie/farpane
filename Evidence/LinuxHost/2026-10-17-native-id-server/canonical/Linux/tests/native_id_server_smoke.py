"""Actual hbbs/hbbr, two private identities, real GTK ID and relay connections.

The orchestrator runs as container root; GUI/Host/server each run as separate
ordinary UIDs. No published ports, Docker socket, devices or host config mounts.
"""
import hashlib
import base64
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import socket
import struct
import subprocess
import sys
import time

from native_host_smoke import RELEASE, stage_release
from native_lifecycle_smoke import Display, colored_pixels

assert Path('/.dockerenv').is_file() and os.geteuid() == 0
SERVER_ADDRESS = '198.18.0.1'
if sys.argv[1:2] == ['--setup-isolated-address']:
    # hbbr 1.1.15 treats loopback TCP clients as its command interface.
    # Assign a benchmark address only inside this --network none namespace,
    # then irrevocably drop NET_ADMIN before starting any product/server.
    assert socket.if_nameindex() == [(1, 'lo')]
    address = socket.inet_aton(SERVER_ADDRESS)
    payload = struct.pack('BBBBI', socket.AF_INET, 32, 0, 254, 1)
    payload += struct.pack('HH', 8, 1) + address
    payload += struct.pack('HH', 8, 2) + address
    message = struct.pack('IHHII', 16 + len(payload), 20, 0x605, 1, 0) + payload
    with socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE) as route:
        route.settimeout(3);route.bind((0, 0));route.sendto(message, (0, 0))
        response=route.recv(4096)
        assert struct.unpack_from('H', response, 4)[0] == 2
        assert struct.unpack_from('i', response, 16)[0] == 0, response.hex()
    os.execv('/usr/bin/setpriv', ['setpriv', '--bounding-set=-net_admin',
        '--inh-caps=-net_admin', '--ambient-caps=-net_admin', sys.executable, '-B',
        __file__, *sys.argv[2:]])
status=Path('/proc/self/status').read_text()
for field in ('CapEff', 'CapBnd', 'CapPrm', 'CapInh', 'CapAmb'):
    assert not int(re.search(r'^'+field+r':\s+(\w+)',status,re.M)[1],16) & (1 << 12)
assert socket.if_nameindex() == [(1, 'lo')]
output = Path(sys.argv[1]);output.mkdir(parents=True)
(output / 'network-capabilities.txt').write_text(status)
stage_release()
core = RELEASE / 'libexec/farpane-core'
tools = Path('/workspace/Build/Linux/rendezvous-test-tools')
pin = json.loads(Path('/workspace/Linux/tests/native-id-server.lock.json').read_text())
for name, detail in pin['files'].items():
    assert hashlib.file_digest((tools / name).open('rb'), 'sha256').hexdigest() == detail['sha256']
(output / 'test-binaries.json').write_text(json.dumps({str(p.relative_to(RELEASE)):
    hashlib.file_digest(p.open('rb'), 'sha256').hexdigest() for p in (RELEASE / 'farpane', core)}, indent=2) + '\n')
(output / 'server-provenance.json').write_text(json.dumps(pin, indent=2) + '\n')
runtime = Path('/run/farpane-native-test')
accounts = {}
for role, uid in (('host', 2101), ('viewer', 2102), ('rendezvous', 2103)):
    name = 'farpane-test-' + role
    try:
        pwd.getpwuid(uid)
        raise AssertionError('Private fixture UID already exists')
    except KeyError:
        pass
    home = runtime / role
    subprocess.run(['useradd', '--uid', str(uid), '--user-group', '--home-dir', str(home),
                    '--no-create-home', '--shell', '/usr/sbin/nologin', name], check=True)
    account = pwd.getpwuid(uid);gid=account.pw_gid
    home.mkdir(mode=0o700);os.chown(home, uid, gid)
    env = dict(os.environ, HOME=str(home), USER=name, LOGNAME=name, XDG_RUNTIME_DIR=str(home),
               DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(home / 'bus'),
               RUSTDESK_FORCED_DISPLAY_SERVER='x11', RUST_LOG='debug', RUST_BACKTRACE='1')
    for variable, leaf in (('XDG_CONFIG_HOME','config'),('XDG_DATA_HOME','data'),
                           ('XDG_CACHE_HOME','cache'),('XDG_STATE_HOME','state')):
        directory=home/leaf;directory.mkdir(mode=0o700);os.chown(directory,uid,gid);env[variable]=str(directory)
    accounts[role]=(uid,gid,env)
processes=[];logs=[];screen=None;remote=None;pattern=None


def start(name, role, args, env=None, cwd=None):
    uid,gid,base=accounts[role]
    log=(output/(name+'.log')).open('w');logs.append(log)
    p=subprocess.Popen(args,env=env or base,cwd=cwd,stdout=log,stderr=subprocess.STDOUT,
                       user=uid,group=gid,extra_groups=[],start_new_session=True)
    processes.append(p)
    return p


def cli(role, command):
    uid,gid,env=accounts[role]
    result=subprocess.run([str(core),'--config-cli'],input=json.dumps(command),text=True,
                          capture_output=True,env=env,user=uid,group=gid,extra_groups=[],timeout=15)
    assert result.returncode==0,result.stderr
    return json.loads(result.stdout)


def wait(predicate, message, timeout=20):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        value=predicate()
        if value:return value
        time.sleep(.08)
    if screen:screen.capture(output/'failure.png')
    raise AssertionError(message)


def process_info(role, pid):
    # Default Docker root lacks CAP_SYS_PTRACE across UIDs. Inspect each
    # process as its own private UID; do not add container privileges.
    uid,gid,env=accounts[role]
    code='''import json,sys,os
from pathlib import Path
p=Path('/proc')/sys.argv[1]
try:
 children=set();sockets=[]
 for task in (p/'task').iterdir():
  try:children.update(int(n) for n in (task/'children').read_text().split())
  except FileNotFoundError:pass
 for fd in (p/'fd').iterdir():
  try:
   target=str(fd.readlink())
   if target.startswith('socket:['):sockets.append(target[8:-1])
  except FileNotFoundError:pass
 print(json.dumps({'exe':str((p/'exe').readlink()),'args':(p/'cmdline').read_bytes().decode().split('\\0'),
                   'children':sorted(children),'sockets':sockets,'uid':os.geteuid()}))
except FileNotFoundError:print('null')
'''
    result=subprocess.run(['python3','-B','-c',code,str(pid)],env=env,user=uid,group=gid,
                          extra_groups=[],capture_output=True,text=True,timeout=3)
    assert result.returncode==0,result.stderr
    return json.loads(result.stdout)


def sockets(role, pid, state='01'):
    info=process_info(role,pid);assert info
    inodes=set(info['sockets'])
    result=[]
    for name in ('tcp','tcp6'):
        for line in Path('/proc/net',name).read_text().splitlines()[1:]:
            fields=line.split()
            if fields[3]==state and fields[9] in inodes:
                result.append({'family':name,'local_hex':fields[1],'remote_hex':fields[2],
                               'local_port':int(fields[1].split(':')[1],16),
                               'remote_port':int(fields[2].split(':')[1],16),'inode':fields[9]})
    return result


def listen(port):
    try:
        with socket.create_connection(('127.0.0.1',port),timeout=.1):return True
    except OSError:return False


def user_state(role, **settings):
    state=cli(role,{'type':'snapshot'})
    if settings:
        server=dict(state['server'],**settings)
        state=cli(role,{'type':'set_server','data':{'settings':server,'revision':state['revision']}})
    return state


try:
    x11=Path('/tmp/.X11-unix');x11.mkdir(exist_ok=True);x11.chmod(0o1777)
    for role in ('host','viewer'):
        home=Path(accounts[role][2]['XDG_RUNTIME_DIR'])
        start(role+'-bus',role,['dbus-daemon','--session','--nofork','--address=unix:path='+str(home/'bus')])
        wait((home/'bus').exists,'Private bus did not start')
    start('host-xvfb','host',['Xvfb',':91','-screen','0','640x480x24','-nolisten','tcp'])
    start('viewer-xvfb','viewer',['Xvfb',':92','-screen','0','1020x720x24','-nolisten','tcp'])
    wait(lambda:Path('/tmp/.X11-unix/X91').exists() and Path('/tmp/.X11-unix/X92').exists(),'Private displays did not start')
    server_home=Path(accounts['rendezvous'][2]['HOME'])
    hbbs=start('hbbs','rendezvous',[str(tools/'hbbs'),'-r',SERVER_ADDRESS+':21117','--mask','198.18.0.0/15'],cwd=server_home)
    wait(lambda:listen(21116) and (server_home/'id_ed25519.pub').exists(),'Private hbbs did not start')
    key=(server_home/'id_ed25519.pub').read_text().strip();assert key
    # Avoid the server's same-instant pair remove/insert race in this same-host
    # fixture. It was observed as two "New relay request" lines for one UUID.
    relay_env=dict(accounts['rendezvous'][2],TOKIO_WORKER_THREADS='1')
    hbbr=start('hbbr','rendezvous',[str(tools/'hbbr')],env=relay_env,cwd=server_home)
    wait(lambda:listen(21117),'Private hbbr did not start')
    host=user_state('host',rendezvous=SERVER_ADDRESS+':21116',relay=SERVER_ADDRESS+':21117',public_key=key,force_relay=False)
    viewer=user_state('viewer',rendezvous=SERVER_ADDRESS+':21116',relay=SERVER_ADDRESS+':21117',public_key=key,force_relay=False)
    assert host['local_id']!=viewer['local_id'],'Isolated fresh identities collided'
    host=cli('host',{'type':'set_authentication','data':{'mode':'permanent','password':'native-id-server-smoke','revision':host['revision']}})
    host=cli('host',{'type':'set_host','data':{'enabled':True,'revision':host['revision']}})
    host_env=dict(accounts['host'][2],DISPLAY=':91')
    agent=start('host','host',[str(core),'--server'],host_env)
    wait(lambda:cli('host',{'type':'snapshot'})['registered'],'Host did not register with actual hbbs',30)
    # hbbs owns 21118 for WebSocket; global port presence says nothing about
    # whether this separate Host enabled the direct-IP listener.
    assert not any(c['local_port']==21118 for c in sockets('host',agent.pid,'0A'))
    (output/'identities.json').write_text(json.dumps({'synthetic_host_id':host['local_id'],
        'synthetic_viewer_id':viewer['local_id'],'distinct_uids':True,
        'server_public_key_sha256':hashlib.sha256(key.encode()).hexdigest(),
        'direct_ip_server_enabled':False},indent=2)+'\n')
    remote,screen=Display(':91'),Display(':92')
    pattern=remote.x.XCreateSimpleWindow(remote.display,remote.root,60,100,480,260,0,0,0)
    remote.x.XMapRaised(remote.display,pattern)
    layout=json.loads(Path('/workspace/Linux/tests/native-lifecycle-layout.json').read_text())
    records=[]
    for index, name in enumerate(('direct','wrong-server-key','relay')):
        relay=name=='relay';negative=name=='wrong-server-key';folder=output/name;folder.mkdir()
        public_key=key
        if negative:
            decoded=bytearray(base64.b64decode(key));assert len(decoded)==32
            decoded[0]^=1;public_key=base64.b64encode(decoded).decode()
        configured=user_state('viewer',force_relay=relay,public_key=public_key)
        color=(0x21906a,0x8030a0,0x3070b0)[index]
        remote.x.XSetWindowBackground(remote.display,pattern,color)
        remote.x.XClearWindow(remote.display,pattern);remote.x.XSync(remote.display,0)
        env=dict(accounts['viewer'][2],DISPLAY=':92',GSK_RENDERER='cairo',GTK_A11Y='none')
        gui=start(name+'-gui','viewer',[str(RELEASE/'farpane')],env)
        def window():
            tree=subprocess.check_output(['xwininfo','-display',':92','-root','-tree'],text=True)
            found=re.search(r'(0x[0-9a-f]+) "FarPane"',tree)
            return int(found[1],16) if found else 0
        wid=wait(window,'GUI did not show');time.sleep(2)
        screen.focus(wid);screen.capture(folder/'home.png')
        diagnostic=Path(accounts['viewer'][2]['XDG_STATE_HOME'])/'farpane/native/viewer.log'
        prior=diagnostic.stat().st_size if diagnostic.exists() else 0
        hbbs_before=(output/'hbbs.log').stat().st_size
        screen.click(layout['peer']);screen.type(host['local_id']);screen.click(layout['connect'])
        def viewer_children():
            result=[]
            for pid in process_info('viewer',gui.pid)['children']:
                info=process_info('viewer',pid)
                if info and info['exe']==str(core) and info['args'][1:2]==['--viewer']:result.append(pid)
            return result
        if negative:
            # A genuine key rejection can finish in <50 ms, before XTest's
            # click returns. Prove terminal state and no remaining child,
            # rather than requiring observation of a transient worker PID.
            def rejected():
                if not diagnostic.exists():return False
                tail=diagnostic.read_bytes()[prior:].decode()
                return '会话状态：Failed' in tail and not process_info('viewer',gui.pid)['children']
            wait(rejected,'Wrong server key did not stop the Viewer',25)
            tail=diagnostic.read_bytes()[prior:].decode()
            assert 'PasswordRequired' not in tail and 'AwaitingFrame' not in tail
            assert 'invalid key' in (output/'hbbs.log').read_bytes()[hbbs_before:].decode()
            (folder/'diagnostic.txt').write_text(tail)
            assert colored_pixels(screen.capture(folder/'rejected.png'),color)<1000
            assert not cli('host',{'type':'snapshot'})['inbound']
            assert not any(c['local_port']==21117 for c in sockets('rendezvous',hbbr.pid))
            screen.click(layout['disconnect']);time.sleep(.3)
            screen.click(layout['close']);assert gui.wait(timeout=10)==0 and agent.poll() is None
            record={'mode':name,'rejected_without_password_submission':True,'worker_reaped':True,
                    'host_inbound_empty':True,'no_relay_pair':True,'host_retained':True}
            records.append(record);(folder/'result.json').write_text(json.dumps(record,indent=2)+'\n')
            print(json.dumps(record),flush=True)
            continue
        ids=wait(viewer_children,'No Viewer worker')
        assert len(ids)==1;worker=ids[0]
        assert process_info('viewer',worker)['exe']==str(core)
        wait(lambda:diagnostic.exists() and 'PasswordRequired' in diagnostic.read_bytes()[prior:].decode(),
             'ID connection did not reach password authentication')
        time.sleep(.3)
        screen.capture(folder/'authentication.png')
        screen.click(layout['password']);screen.type('native-id-server-smoke');screen.click(layout['authenticate'])
        pixels=wait(lambda:(n if (n:=colored_pixels(screen.capture(),color))>15000 else 0),
                    'ID connection did not render current remote pixels',30)
        inbound=cli('host',{'type':'snapshot'})['inbound']
        assert len(inbound)==1 and inbound[0]['authorized']
        connections={name:sockets(role,pid) for name,role,pid in
                     [('viewer','viewer',worker),('host','host',agent.pid),('hbbr','rendezvous',hbbr.pid)]}
        assert any(c['remote_port']==21117 for c in connections['viewer'])==relay,connections
        if relay:
            assert any(c['remote_port']==21117 for c in connections['host'])
            assert len([c for c in connections['hbbr'] if c['local_port']==21117])==2
            assert 'got paired' in (output/'hbbr.log').read_text()
        else:assert not [c for c in connections['hbbr'] if c['local_port']==21117]
        screen.capture(folder/'streaming.png')
        (folder/'transport-sockets.json').write_text(json.dumps(connections,indent=2)+'\n')
        screen.click(layout['disconnect'])
        wait(lambda:not viewer_children() and not Path(f'/proc/{worker}').exists(),'Viewer not reaped')
        wait(lambda:not cli('host',{'type':'snapshot'})['inbound'],'Host retained session')
        wait(lambda:not any(c['local_port']==21117 for c in sockets('rendezvous',hbbr.pid)),
             'Relay retained an established socket after disconnect')
        after=user_state('viewer');assert after['local_id']==viewer['local_id'] and after['server']==configured['server']
        assert len(after['devices'])==1 and after['devices'][0]['peer']==host['local_id']
        screen.click(layout['close']);assert gui.wait(timeout=10)==0 and agent.poll() is None
        record={'mode':name,'force_relay':relay,'worker_pid':worker,'worker_reaped':True,
                'remote_pixels':pixels,'host_retained':True,'actual_id_lookup':True,'direct_ip_server_disabled':True}
        records.append(record);(folder/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record),flush=True)
    result={'result':'pass','connections':records,'real_hbbs_hbbr':True,'same_host_process':agent.pid,
            'network':'isolated-namespace-benchmark-address','server_address':SERVER_ADDRESS,
            'net_admin_dropped_before_application':True,'hbbr_tokio_workers':1,
            'gpu':False,'real_desktop':False,'product_rebuilt':False,
            'installed_services_touched':False}
    (output/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True)
finally:
    if pattern and remote:remote.x.XDestroyWindow(remote.display,pattern)
    if screen:screen.close()
    if remote:remote.close()
    for p in reversed(processes):
        if p.poll() is None:
            p.terminate()
            try:p.wait(timeout=3)
            except subprocess.TimeoutExpired:p.kill();p.wait()
    for f in logs:f.close()
    for role,(_,_,env) in accounts.items():
        for p in Path(env['HOME']).rglob('*.log'):
            target=output/'core-logs'/role/p.relative_to(Path(env['HOME']))
            target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,target)
