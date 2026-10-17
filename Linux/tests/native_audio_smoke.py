"""Synthetic sound through actual Host/Opus/network/Viewer/Pulse playback."""
import array
import json
import math
import os
import re
from pathlib import Path
import select
import subprocess
import time
from native_host_smoke import cli, RELEASE


def setup_audio(output, start):
    assert Path('/.dockerenv').exists() and not Path('/dev/snd').exists()
    audio_config=Path(os.environ['XDG_RUNTIME_DIR'])/'pulse-config';audio_config.mkdir()
    (audio_config/'daemon.conf').write_text('')
    (audio_config/'client.conf').write_text('autospawn = no\n')
    os.environ['PULSE_CONFIG_PATH']=str(audio_config)
    socket = Path(os.environ['XDG_RUNTIME_DIR'])/'test-pulse.sock'
    config = output/'pulse.pa'
    config.write_text(f'''load-module module-native-protocol-unix socket={socket} auth-anonymous=1
load-module module-null-sink sink_name=host_audio rate=48000 channels=2
load-module module-null-sink sink_name=viewer_audio rate=48000 channels=2
load-module module-remap-source source_name=synthetic_mic master=host_audio.monitor
set-default-sink viewer_audio
set-default-source synthetic_mic
''')
    os.environ['PULSE_SERVER'] = f'unix:{socket}'
    os.environ['PULSE_SINK'] = 'viewer_audio'
    pulse = start('pulse', ['pulseaudio', '--daemonize=no', '--exit-idle-time=-1', '--use-pid-file=no',
                           '--disallow-exit=yes', '-n', '-F', str(config)])
    deadline = time.monotonic()+5
    while not socket.exists():
        assert pulse.poll() is None, 'Private audio daemon exited'
        assert time.monotonic()<deadline
        time.sleep(.05)
    sources = json.loads(subprocess.check_output(['pactl','--format=json','list','sources'], text=True))
    assert any(s['name']=='synthetic_mic' for s in sources), sources
    (output/'pulse-sources.json').write_text(json.dumps(sources, indent=2))
    # 440 Hz, -14 dBFS, stereo; repeat the same bounded one-second block in a file.
    block = array.array('f', [0.2*math.sin(2*math.pi*440*(i//2)/48000) for i in range(96000)])
    tone = output/'tone.f32'
    with tone.open('wb') as f:
        for _ in range(90): block.tofile(f)
    start('tone', ['pacat','--playback','--raw','--format=float32le','--rate=48000','--channels=2',
                   '--device=host_audio',str(tone)])
    state=cli({'type':'snapshot'})
    cli({'type':'set_host_audio','data':{'enabled':True,'source':'host_audio.monitor',
        'microphone':False,'revision':state['revision']}})
    # Simulate a previous release's named input before the agent takes ownership.
    settings=next(Path(os.environ['XDG_CONFIG_HOME']).rglob('FarPane2.toml'))
    text=re.sub(r'(?m)^farpane-audio-(?:source|choice|microphone|enabled)\s*=.*\n','',settings.read_text())
    text=text.replace('[options]\n','[options]\naudio-input = "Legacy microphone description"\n',1)
    settings.write_text(text)
    assert cli({'type':'snapshot'})['audio_needs_selection']
    return pulse


class Meter:
    def __init__(self, device="viewer_audio.monitor"):
        self.process = subprocess.Popen(['parec','--raw','--format=float32le','--rate=48000','--channels=2',
                                         '--latency-msec=20',f'--device={device}'],stdout=subprocess.PIPE)
        os.set_blocking(self.process.stdout.fileno(),False)
        self.tail=b''
    def measure(self, duration=.35):
        # Discard accumulated historical monitor samples before observing a state.
        while select.select([self.process.stdout],[],[],0)[0]:
            if not os.read(self.process.stdout.fileno(),65536): break
        data=bytearray();began=time.monotonic();deadline=began+2.5
        while time.monotonic()<deadline and (time.monotonic()<began+duration or len(data)<8008):
            if select.select([self.process.stdout],[],[],.05)[0]:
                chunk=os.read(self.process.stdout.fileno(),65536)
                assert chunk, 'Monitor stream ended'
                data.extend(chunk)
        data=self.tail+data;n=len(data)//8*8;self.tail=data[n:]
        samples=array.array('f');samples.frombytes(data[:n]); samples=samples[::2]
        assert len(samples)>1000, 'Insufficient private sink samples'
        rms=math.sqrt(sum(x*x for x in samples)/len(samples))
        crossings=sum(a<0<=b for a,b in zip(samples,samples[1:]))
        return {'rms':rms,'hz':crossings*48000/len(samples),'samples':len(samples)}
    def close(self):
        if self.process.poll() is None:self.process.terminate()
        self.process.wait(timeout=3)


def exercise_audio(directory, pulse, fault=False):
    observations=[]
    def status():
        try:
            events=json.loads((directory/'viewer-progress.json').read_text())['events']
            return [e['event']['data'] for e in events if e['event']['type']=='audio']
        except (FileNotFoundError,json.JSONDecodeError):return []
    def wait_status(wanted, after=0):
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            values=status()
            if len(values)>after and values[-1]['status']==wanted:return
            time.sleep(.05)
        raise AssertionError((wanted,status()))
    def toggle(enabled):
        previous=len(status());(directory/('audio-on' if enabled else 'audio-off')).touch()
        wait_status('playing' if enabled else 'disabled',previous)
        time.sleep(.25)
    def expect(meter, audible, label):
        deadline=time.monotonic()+3
        while True:
            sample=meter.measure()
            if (sample['rms']>.04 and abs(sample['hz']-440)<20) if audible else sample['rms']<1e-5:break
            assert time.monotonic()<deadline,(label,sample)
        sample.update(label=label,audible=audible);observations.append(sample)
        (directory/'audio-observations.json').write_text(json.dumps(observations,indent=2))
    meter=Meter()
    try:
        time.sleep(.3);expect(meter,False,'disabled-before-enable')
        toggle(True)
        diagnostic={}
        for kind in ['sinks','sources','sink-inputs','source-outputs']:
            diagnostic[kind]=json.loads(subprocess.check_output(['pactl','--format=json','list',kind],text=True))
        host=Meter('host_audio.monitor')
        try: diagnostic['source_measurement']=host.measure()
        finally:host.close()
        (directory/'pulse-playing.json').write_text(json.dumps(diagnostic,indent=2))
        expect(meter,True,'decoded-440hz')
        toggle(False);expect(meter,False,'disabled-no-tail')
        toggle(True);expect(meter,True,'reenabled-440hz')
        state=cli({'type':'snapshot'})
        (directory/'host-audio-state.json').write_text(json.dumps(state,indent=2))
        assert state['audio_sources'] and not state['audio_error'],state
        assert any(s['microphone'] and s['id']=='synthetic_mic' for s in state['audio_sources'])
        assert any(not s['microphone'] and s['id']=='host_audio.monitor' for s in state['audio_sources'])
        assert state['sharing']['audio_source']=='host_audio.monitor' and not state['sharing']['microphone']
        previous=len(status())
        if fault:
            # This Popen is the daemon created by setup_audio inside this container.
            assert pulse.poll() is None
            pulse.terminate();pulse.wait(timeout=3)
            wait_status('unavailable',previous)
            report=json.loads((directory/'viewer-progress.json').read_text())
            assert report['presented'] and not report['worker_reaped']
            before=report['frames'];(directory/'audio-refresh-video').touch()
            (directory/'audio-failure.json').write_text(json.dumps({'private_pulse_exit':pulse.returncode,
                'audio_unavailable':True,'video_frames_before_refresh':before}))
        else:
            connections=[c for c in state['inbound'] if c['authorized']]
            assert len(connections)==1,connections
            env=dict(os.environ,DISPLAY=':92',FARPANE_REVOKE_AUDIO_SMOKE_DIR=str(directory),GSK_RENDERER='cairo',GTK_A11Y='none')
            # A second private D-Bus session permits the Host UI and Viewer to be
            # exercised concurrently; both use the same real agent control socket.
            with (directory/'revoke-ui.log').open('w') as log:
                result=subprocess.run(['dbus-run-session','--',str(RELEASE/'farpane')],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=15)
            assert result.returncode==0
            assert json.loads((directory/'revoke-ui.json').read_text())['result']=='pass'
            assert 'CRITICAL' not in (directory/'revoke-ui.log').read_text()
            wait_status('disabled',previous);time.sleep(.25)
            expect(meter,False,'remote-revocation-no-tail')
        (directory/'audio-result.json').write_text(json.dumps({'observations':observations,'source_classification':True,
            'selected_monitor_not_default_microphone':True,'permission_revoked':not fault,'audio_service_failure':fault},indent=2))
    finally:meter.close()


def exercise_audio_ui(output):
    directory=output/'audio-ui';directory.mkdir()
    env=dict(os.environ,DISPLAY=':92',FARPANE_AUDIO_UI_SMOKE_DIR=str(directory),GSK_RENDERER='cairo',GTK_A11Y='none')
    with (directory/'gui.log').open('w') as log:
        result=subprocess.run([str(RELEASE/'farpane')],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=30)
    assert result.returncode==0,result.returncode
    assert json.loads((directory/'audio-ui.json').read_text())['result']=='pass'
    assert 'CRITICAL' not in (directory/'gui.log').read_text()
