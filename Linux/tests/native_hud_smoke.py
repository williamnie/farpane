"""HUD + real save dialog + own-process /proc samples, private container only."""
import json,os,re,time,shutil
from pathlib import Path
from native_host_smoke import cli,RELEASE

def exercise_hud(output,agent,start):
    initial=cli({'type':'snapshot'});results=[]
    for mode in ['normal','log-failure']:
        directory=output/mode;directory.mkdir()
        env=dict(os.environ,DISPLAY=':92',GSK_RENDERER='cairo',GTK_A11Y='none',GTK_USE_PORTAL='0',FARPANE_VIEWER_SMOKE_DIR=str(directory),FARPANE_HUD_SMOKE_DIR=str(directory))
        if mode=='log-failure':
            blocked=directory/'state-is-a-file';blocked.write_text('preserve this fixture')
            env.update(XDG_STATE_HOME=str(blocked),FARPANE_HUD_LOG_FAILURE='1')
        gui=start('hud-'+mode,[str(RELEASE/'farpane')],env)
        deadline=time.monotonic()+55;sampled=False
        while gui.poll() is None and time.monotonic()<deadline:
            active=directory/'hud-active.json'
            if active.exists() and not sampled:
                sample=json.loads(active.read_text());processes={}
                for role,resource in [('gui',sample['gui']),('viewer',sample['worker']['resources'])]:
                    pid=resource['pid'];exe=Path(f'/proc/{pid}/exe').resolve()
                    assert exe==(RELEASE/'farpane' if role=='gui' else RELEASE/'libexec/farpane-core'),(role,exe)
                    if role=='gui':assert pid==gui.pid
                    else:
                        assert b'--viewer\0' in Path(f'/proc/{pid}/cmdline').read_bytes()
                        assert int(re.search(r'^PPid:\s+(\d+)',Path(f'/proc/{pid}/status').read_text(),re.M)[1])==gui.pid
                    raw=Path(f'/proc/{pid}/smaps_rollup').read_text();(directory/f'{role}-smaps-rollup.txt').write_text(raw)
                    current=int(re.search(r'^Pss:\s+(\d+)',raw,re.M)[1]);delta=abs(current-resource['pss_kib'])
                    assert delta<16*1024,(role,'PSS drift beyond 16 MiB',current,resource)
                    assert resource['rss_kib']>=resource['pss_kib']>0 and resource['uss_kib']>0
                    assert 0<=resource['cpu_percent']<=450 and resource['fds']>0 and resource['threads']>0
                    processes[role]={'pid':pid,'reported_pss_kib':resource['pss_kib'],'observed_pss_kib':current,'sample_age_ms':resource['age_ms']}
                (directory/'process-cross-check.json').write_text(json.dumps(processes,indent=2));sampled=True
            time.sleep(.05)
        assert gui.poll()==0,'HUD GUI did not finish successfully'
        result=json.loads((directory/'hud-result.json').read_text());assert result['result']=='pass',result
        assert sampled
        video=json.loads((directory/'viewer.json').read_text());assert video['presented'] and video['worker_reaped']
        active=json.loads((directory/'hud-active.json').read_text());idle=json.loads((directory/'hud-idle.json').read_text())
        assert active['present_fps']>0 and active['worker']['decode_fps']>0
        assert idle['present_fps']==0 and idle['worker']['packet_rate']==0 and idle['worker']['decode_fps']==0
        for filename in ['hud.png','diagnostics.png']:assert (directory/filename).read_bytes().startswith(b'\x89PNG')
        raw=(directory/'diagnostics.json').read_text();data=json.loads(raw)
        assert len(data['log_entries'])<=2000 and len(raw)<2*1024*1024
        assert data['performance_age_ms']>=1000
        assert data['performance']['gui']['pss_kib']>0 and data['performance']['worker']['resources']['pss_kib']>0
        forbidden=['native-viewer-smoke','incorrect-smoke-password','127.0.0.1',initial['local_id'],str(directory)]
        for marker in forbidden:assert marker not in raw,marker
        assert (directory/'diagnostics.json').stat().st_mode&0o077==0
        assert agent.poll() is None
        after=cli({'type':'snapshot'})
        for key in ['local_id','authentication','permanent_password_set','host_enabled','sharing','server','gpu_enabled']:assert after[key]==initial[key],key
        if mode=='normal':
            folder=Path(env['XDG_STATE_HOME'])/'farpane/native';logs=list(folder.glob('viewer.log*'));assert logs
            for path in logs:
                assert path.stat().st_size<=512*1024 and path.stat().st_mode&0o077==0
                contents=path.read_text();assert contents.startswith('# FarPane native session log v1\n')
                for marker in forbidden:assert marker not in contents,marker
                shutil.copy2(path,directory/path.name)
        else:assert blocked.read_text()=='preserve this fixture'
        assert 'CRITICAL' not in (output/f'hud-{mode}.log').read_text()
        results.append({'mode':mode,**result})
    result={'result':'pass','rounds':results,'scope':'private Xvfb, real loopback, actual GTK widgets and save dialog; no host services/GPU'}
    (output/'hud-result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result,indent=2))
