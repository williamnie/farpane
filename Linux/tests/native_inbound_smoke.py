"""Actual inbound controls in the same GTK process as an outbound Viewer."""
import json,os,time
from native_host_smoke import cli,RELEASE

def exercise_inbound(output,agent,start):
    state=cli({'type':'snapshot'})
    state=cli({'type':'set_authentication','data':{'mode':'approval','password':None,'revision':state['revision']}})
    assert state['authentication']=='approval' and state['host_enabled']
    results=[]
    for action in ['approve','reject','timeout']:
        directory=output/action;directory.mkdir()
        env=dict(os.environ,DISPLAY=':92',GSK_RENDERER='cairo',GTK_A11Y='none',
                 FARPANE_VIEWER_SMOKE_DIR=str(directory),FARPANE_INBOUND_SMOKE_DIR=str(directory),FARPANE_INBOUND_ACTION=action)
        gui=start('inbound-'+action,[str(RELEASE/'farpane')],env)
        deadline=time.monotonic()+48
        while gui.poll() is None and time.monotonic()<deadline:time.sleep(.1)
        assert gui.poll()==0,'Inbound GUI did not complete'
        report=json.loads((directory/'inbound-result.json').read_text());assert report['result']=='pass',report
        video=json.loads((directory/'viewer.json').read_text())
        assert video['worker_reaped'] and video['password_attempts']==0
        assert video['presented']==(action=='approve')
        if action!='approve':assert video['frames']==0,'Frame arrived without approval'
        assert (directory/'inbound-controls.png').read_bytes().startswith(b'\x89PNG')
        assert 'CRITICAL' not in (output/f'inbound-{action}.log').read_text()
        after=cli({'type':'snapshot'});assert after['inbound']==[]
        assert agent.poll() is None,'GUI action terminated Host'
        assert after['revision']==state['revision']+1,'Non-approved connection altered history/config'
        assert len(after['devices'])==1 and after['devices'][0]['peer']=='127.0.0.1:21118'
        for key in ['local_id','authentication','permanent_password_set','server','sharing','gpu_enabled','host_enabled']:
            assert state[key]==after[key],key
        results.append(report)
    (output/'inbound-result.json').write_text(json.dumps({'result':'pass','checks':['actual-viewer-local-connection-dialog','approve-before-first-frame','keyboard-revoke-reaches-peer','actual-disconnect-button','reject-no-frames','unanswered-request-expires','worker-reaped','host-retained','config-and-identity-preserved'],'rounds':results},indent=2))
    print((output/'inbound-result.json').read_text())
