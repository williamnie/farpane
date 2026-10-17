"""Real clipboard selections on two private X servers through GTK + Viewer + Host.
Only synthetic content is read/written. Called inside the existing isolated runner.
"""
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import threading
import time
import zlib


def png_fixture(width=320, height=192):
    # Opaque varied pixels, >64 KiB on wire: exercise the separate payload channel.
    pixels=bytes(component for y in range(height) for x in range(width)
                 for component in ((x*13+y*3)%256,(x*7+y*11)%256,(x*y+17)%256,255))
    def chunk(kind,data):return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)
    raw=b''.join(b'\0'+pixels[y*width*4:(y+1)*width*4] for y in range(height))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',width,height,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw,1))+chunk(b'IEND',b'')


def exercise(directory, helper):
    from native_host_smoke import cli, RELEASE
    owners=[]; focus_owners=[]; checks=[]; counter=0; transactions=[]
    def note(name):
        checks.append(name)
        (directory/'clipboard-result.json').write_text(json.dumps({'checks':checks,'host_policy_transactions':len(transactions),'policy_revisions':transactions},indent=2))
    def all_policy(send=False, receive=False):
        return {k:{'send':send,'receive':receive} for k in ('text','rich_text','image')}
    def wait_policy(expected):
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            try:
                events=json.loads((directory/'viewer-progress.json').read_text())['events']
                policies=[e['event']['data'] for e in events if e['event']['type']=='clipboard_policy']
                if policies and policies[-1]['policy']==expected:return
            except (FileNotFoundError,json.JSONDecodeError):pass
            time.sleep(.05)
        raise AssertionError('Clipboard policy was not acknowledged')
    def configure(policy):
        pending=directory/'clipboard-policy.next'
        pending.write_text(json.dumps(policy));pending.replace(directory/'clipboard-policy.json');wait_policy(policy)
    def host_policy(policy):
        before=cli({'type':'snapshot'})
        after=cli({'type':'set_host_clipboard','data':{'policy':policy,'revision':before['revision']}})
        transactions.append({'before':before['revision'],'after':after['revision']})
        assert after['revision']==before['revision']+1
        assert after['sharing']['clipboard']==policy
        for key in ('audio_source','microphone','receive_directory','confirm_files'):
            assert after['sharing'][key]==before['sharing'][key]
        assert after['local_id']==before['local_id'] and after['server']==before['server']
        return after
    def own(display, parts, stall=False):
        nonlocal counter
        counter+=1;args=[str(helper),'set-stall' if stall else 'set-data',display]
        for index,(mime,data) in enumerate(parts):
            path=directory/f'synthetic-{counter}-{index}.bin';path.write_bytes(data);args.extend([mime,str(path)])
        with (directory/f'selection-owner-{counter}.log').open('w') as log:
            process=subprocess.Popen(args,stdout=subprocess.PIPE,stderr=log,text=True)
        owners.append(process);assert process.stdout.readline().strip()=='READY'
    def read(display,mime='UTF8_STRING'):
        path=directory/'selection-read.bin'
        began=time.monotonic()
        result=subprocess.run([str(helper),'get-data',display,mime,str(path)],capture_output=True,timeout=5)
        with (directory/'selection-reads.jsonl').open('a') as log:
            log.write(json.dumps({'display':display,'mime':mime,'returncode':result.returncode,
                'milliseconds':int((time.monotonic()-began)*1000),'bytes':path.stat().st_size,
                'stderr':result.stderr.decode(errors='replace')[:1000]})+'\n')
        return path.read_bytes() if result.returncode==0 else None
    def expect(display,data,mime='UTF8_STRING'):
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            value=read(display,mime)
            if value==data:return
            time.sleep(.08)
        raise AssertionError(f'Clipboard {mime} did not arrive on private display {display} ({len(data)} bytes)')
    def phase():
        return json.loads((directory/'viewer-progress.json').read_text())['phase']
    try:
        subprocess.run([str(helper),'focus',':92'],check=True)
        text=all_policy();text['text']={'send':True,'receive':True};wait_policy(text)
        local='native-gui-to-host 文本'.encode();remote='native-host-to-gui 文本'.encode()
        own(':92',[('UTF8_STRING',local)]);expect(':91',local)
        own(':91',[('UTF8_STRING',remote)]);expect(':92',remote)
        note('text_two_directions')
        large=b'z'*65536
        own(':92',[('UTF8_STRING',large)]);expect(':91',large)
        own(':92',[('UTF8_STRING',b'x'*65537)]);time.sleep(.5);assert read(':91')==large
        note('text_64k_boundary_and_oversize_rejected')
        # Text permission does not authorize rich formats or image reads.
        own(':92',[('text/html',b'<p>disabled</p>')]);time.sleep(.4);assert read(':91')==large
        note('rich_default_disabled')
        own(':91',[('UTF8_STRING',b'b'*65536)]);expect(':92',b'b'*65536)
        own(':91',[('UTF8_STRING',b'c'*65537)]);time.sleep(.5);assert read(':92')==b'b'*65536
        note('host_text_limit_before_incr_allocation')
        own(':91',[('UTF8_STRING',b'never-completes')],stall=True)
        stalled=counter
        deadline=time.monotonic()+2
        while 'request UTF8_STRING' not in (directory/f'selection-owner-{stalled}.log').read_text():
            assert time.monotonic()<deadline;time.sleep(.03)
        began=time.monotonic()
        assert cli({'type':'snapshot'})['role']=='agent'
        own(':91',[('UTF8_STRING',b'after-stalled-owner')]);expect(':92',b'after-stalled-owner')
        assert time.monotonic()-began<4.5 and phase()=='streaming'
        note('stalled_host_owner_has_total_timeout_and_control_video_survive')

        rich=all_policy();rich['rich_text']={'send':True,'receive':True};configure(rich)
        for display,destination,tag in [(':92',':91',b'local'),(':91',':92',b'remote')]:
            html=b'<p><b>'+tag+b'</b>'+b'h'*70000+b'</p>'
            rtf=b'{\\rtf1 '+tag+b' '+b'r'*70000+b'}';plain=tag+b' fallback'
            own(display,[('text/html',html),('text/rtf',rtf),('UTF8_STRING',plain)])
            expect(destination,html,'text/html');expect(destination,rtf,'text/rtf');expect(destination,plain)
        note('rich_bundle_both_directions_with_text_fallback_and_incr')
        # Rich permission alone must not forward a plain-only selection.
        before=read(':91','text/html');own(':92',[('UTF8_STRING',b'plain-only-denied')]);time.sleep(.5)
        assert read(':91','text/html')==before
        note('rich_grant_does_not_grant_plain_only')
        image=all_policy();image['image']={'send':True,'receive':True};configure(image)
        png=png_fixture();assert len(png)>65536
        own(':92',[('image/png',png)]);expect(':91',png,'image/png')
        # Peer offers PNG + RGBA alternatives; Viewer selects the PNG without
        # decompressing a second representation. Distinct bytes avoid echo.
        png2=png_fixture(321,193)
        own(':91',[('image/png',png2)]);expect(':92',png2,'image/png')
        note('png_both_directions_above_control_limit_and_peer_alternatives')
        if os.environ.get('FARPANE_CLIPBOARD_LARGE')=='1':
            from native_clipboard_writer_smoke import synthetic_png
            path=directory/'large-source.png';synthetic_png(path,128*1024*1024)
            large_png=path.read_bytes()
            samples=[];stop=threading.Event()
            processes=json.loads((directory/'process-sample.json').read_text())['processes']
            def starttime(pid):return Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[19]
            starts={role:starttime(value['pid']) for role,value in processes.items()}
            def sample():
                while not stop.is_set() and len(samples)<600:
                    values={'monotonic':time.monotonic()}
                    for role,process in processes.items():
                        try:
                            pid=process['pid'];assert starttime(pid)==starts[role]
                            fields={line.split(':',1)[0]:int(line.split()[1]) for line in Path(f'/proc/{pid}/smaps_rollup').read_text().splitlines() if line.startswith(('Pss:','Rss:','Private_Dirty:'))}
                            values[role]=fields
                        except (OSError,AssertionError,IndexError):values[role]=None
                    samples.append(values);stop.wait(.1)
            sampler=threading.Thread(target=sample);sampler.start()
            try:
                own(':92',[('image/png',large_png)]);expect(':91',large_png,'image/png')
                # Change a private ancillary payload byte and its CRC through
                # regeneration to avoid any same-content cache shortcut.
                synthetic_png(path,128*1024*1024-1);other=path.read_bytes()
                own(':91',[('image/png',other)]);expect(':92',other,'image/png')
                assert phase()=='streaming'
                (directory/'large-clipboard-result.json').write_text(json.dumps({
                    'result':'pass','sent_bytes':len(large_png),'received_bytes':len(other),
                    'sent_sha256':hashlib.sha256(large_png).hexdigest(),'received_sha256':hashlib.sha256(other).hexdigest(),
                    'scope':'actual GTK/Viewer/Host loopback; real two-pixel PNG with ancillary padding; not maximum pixel dimensions'},indent=2))
                note('actual_large_png_both_directions')
            finally:
                stop.set();sampler.join(timeout=2);assert not sampler.is_alive()
                (directory/'large-clipboard-samples.json').write_text(json.dumps({'sample_interval_seconds':.1,'samples':samples},indent=2))
            del large_png,other
        for display,destination,tag in [(':92',':91',b'local'),(':91',':92',b'remote')]:
            svg=b'<svg xmlns="http://www.w3.org/2000/svg" width="2" height="1"><text>'+tag+b'</text></svg>'
            own(display,[('image/svg+xml',svg)]);expect(destination,svg,'image/svg+xml')
        note('svg_both_directions_without_rasterizing')
        configure(text)
        for index in range(8):
            value=f'rapid-local-{index}'.encode();own(':92',[('UTF8_STRING',value)]);expect(':91',value)
            value=f'rapid-remote-{index}'.encode();own(':91',[('UTF8_STRING',value)]);expect(':92',value)
        note('x11_notifications_survive_16_alternating_selections_without_settle_sleep')
        # Native Host policy is independent from Viewer consent. Disabled formats
        # must not be requested from the local selection owner at all.
        host_policy(text)
        own(':91',[('text/html',b'<b>host-disabled-rich</b>'),('image/png',png_fixture())])
        owner_index=counter;time.sleep(.5)
        requests=(directory/f'selection-owner-{owner_index}.log').read_text()
        assert 'request TARGETS' in requests, 'Host did not inspect permitted selection metadata'
        assert 'request image/png' not in requests and 'request text/html' not in requests
        note('host_policy_rejects_formats_before_reading_payload')
        configure(all_policy(True,True))
        own(':92',[('text/html',b'<b>receive-denied</b>')]);time.sleep(.5)
        assert read(':91','text/html')==b'<b>host-disabled-rich</b>'
        note('host_rejects_ungranted_incoming_rich_text')
        host_send=all_policy();host_send['text']['send']=True;host_policy(host_send)
        own(':91',[('UTF8_STRING',b'host-send-only')]);expect(':92',b'host-send-only')
        own(':92',[('UTF8_STRING',b'host-receive-denied')]);time.sleep(.5);assert read(':91')==b'host-send-only'
        host_receive=all_policy();host_receive['text']['receive']=True;host_policy(host_receive)
        own(':92',[('UTF8_STRING',b'host-receive-only')]);expect(':91',b'host-receive-only')
        own(':91',[('UTF8_STRING',b'host-send-denied')]);time.sleep(.5);assert read(':92')==b'host-receive-only'
        note('host_independent_send_and_receive_revocation')
        host_policy(all_policy(True,True));configure(text)

        # Verify one-way policy and disabled content retention on the opposite side.
        outgoing=all_policy();outgoing['text']['send']=True;configure(outgoing)
        own(':92',[('UTF8_STRING',b'one-way')]);expect(':91',b'one-way')
        own(':91',[('UTF8_STRING',b'no-receive')]);time.sleep(.5);assert read(':92')==b'one-way'
        note('receive_revocation')
        focus=subprocess.Popen([str(helper),'unfocus',':92'],stdout=subprocess.PIPE,text=True);focus_owners.append(focus)
        assert focus.stdout.readline().strip()=='READY';time.sleep(.25)
        own(':92',[('UTF8_STRING',b'after-refocus')]);time.sleep(.5);assert read(':91')==b'no-receive'
        subprocess.run([str(helper),'focus',':92'],check=True);expect(':91',b'after-refocus')
        note('focus_loss_pauses_send_and_refocus_reads_current_selection')
        configure(all_policy())
        own(':92',[('UTF8_STRING',b'must-not-leave')]);time.sleep(.5);assert read(':91')==b'after-refocus'
        note('all_disabled_does_not_send')
        assert phase()=='streaming', 'Clipboard operation stopped video'
        note('video_continues')
        progress=(directory/'viewer-progress.json').read_bytes()
        assert all(marker not in progress for marker in (local,remote,b'h'*100,b'r'*100,b'must-not-leave'))
        note('control_events_do_not_contain_selection_payload')
        # Re-enable Viewer consent, then revoke the actual Host connection using
        # the same GUI button as the user; keep video alive throughout.
        configure(text)
        env=dict(os.environ,DISPLAY=':92',FARPANE_REVOKE_CLIPBOARD_SMOKE_DIR=str(directory),GSK_RENDERER='cairo',GTK_A11Y='none')
        with (directory/'revoke-ui.log').open('w') as log:
            result=subprocess.run(['dbus-run-session','--',str(RELEASE/'farpane')],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=15)
        assert result.returncode==0
        assert json.loads((directory/'revoke-ui.json').read_text())['result']=='pass'
        subprocess.run([str(helper),'focus',':92'],check=True)
        own(':91',[('UTF8_STRING',b'host-revoked')]);own(':92',[('UTF8_STRING',b'viewer-revoked')]);time.sleep(.7)
        assert read(':91')==b'host-revoked' and read(':92')==b'viewer-revoked'
        assert phase()=='streaming'
        note('actual_host_connection_revoke_stops_both_directions_and_preserves_video')
        host_policy(all_policy())
        assert not cli({'type':'snapshot'})['sharing']['permissions']['clipboard']
        note('host_all_off_persists')
        # Observe the real named Host thread after all-off has settled; the
        # worker should block on its wake descriptor instead of polling data.
        own(':91',[('UTF8_STRING',b'host-disabled-idle')]);idle_owner=counter
        time.sleep(.2)
        host_pid=json.loads((directory/'process-sample.json').read_text())['processes']['host']['pid']
        tasks=[p for p in Path(f'/proc/{host_pid}/task').iterdir() if (p/'comm').read_text().strip()=='host-clipboard']
        assert len(tasks)==1
        def ticks():
            fields=(tasks[0]/'stat').read_text().rsplit(')',1)[1].split()
            return int(fields[11])+int(fields[12])
        before=ticks();time.sleep(.5);after=ticks()
        assert after-before<=1
        assert 'request ' not in (directory/f'selection-owner-{idle_owner}.log').read_text()
        (directory/'host-clipboard-idle.json').write_text(json.dumps({'cpu_tick_delta':after-before,
            'interval_seconds':.5,'thread_count':len(tasks),'new_selection_read_requests':0},indent=2))
        note('host_all_off_idle_thread_and_no_platform_payload_reads')


        (directory/'clipboard-complete').touch()
    finally:
        (directory/'selection-owner-status.json').write_text(json.dumps([{'index':i+1,'exit_before_cleanup':p.poll()} for i,p in enumerate(owners)]))
        for owner in owners+focus_owners:
            if owner.poll() is None:owner.terminate();owner.wait(timeout=3)


def exercise_host_ui(output):
    from native_host_smoke import RELEASE, cli
    directory=output/'host-clipboard-ui';directory.mkdir()
    before=cli({'type':'snapshot'})
    env=dict(os.environ,DISPLAY=':92',FARPANE_HOST_CLIPBOARD_UI_DIR=str(directory),GSK_RENDERER='cairo',GTK_A11Y='none')
    with (directory/'gui.log').open('w') as log:
        result=subprocess.run([str(RELEASE/'farpane')],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=30)
    assert result.returncode==0
    assert json.loads((directory/'host-clipboard-ui.json').read_text())['result']=='pass'
    after=cli({'type':'snapshot'})
    assert after['revision']==before['revision']+12
    assert after['sharing']==before['sharing'] and after['local_id']==before['local_id']
    assert 'CRITICAL' not in (directory/'gui.log').read_text()
