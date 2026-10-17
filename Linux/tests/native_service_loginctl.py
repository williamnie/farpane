#!/usr/bin/python3
"""Controlled session discovery for the owned service test; never installed."""
import json
from pathlib import Path
import sys
import time

state=json.loads(Path('/run/farpane-service-test/session.json').read_text())
args=sys.argv[1:]
fault=state.get('fault')
if fault=='error':raise SystemExit(1)
if fault=='hang':time.sleep(30)
if fault=='malformed':print('not properties');raise SystemExit(0)
if args and args[0]=='show-seat':
    print('ActiveSession='+state.get('sid',''));raise SystemExit(0)
if args and args[0]=='show-user':
    sessions=[s for s in [state,*state.get('extra_sessions',[])] if str(s.get('uid'))==args[1]]
    print('Sessions='+' '.join(s['sid'] for s in sessions));raise SystemExit(0)
if not state:
    raise SystemExit(0)
sid=state['sid']
if not args:
    print(sid,state['uid'],state['name'],'seat0')
elif args[0]=='show-session':
    selected=next((s for s in [state,*state.get('extra_sessions',[])] if s.get('sid') in args),None)
    if selected is None:
        print('State=closing');raise SystemExit(0)
    state=selected;sid=state['sid']
    values={'Id':sid,'User':str(state['uid']),'Name':state['name'],
            'Active':state.get('active','yes'),'State':state.get('state','active'),'Seat':'seat0','Type':state.get('type','x11'),
            'Remote':'no','Leader':str(state.get('leader',0)),
            'Display':state.get('display',':92'),'LockedHint':'no','Class':state.get('class','user')}
    if '-p' in args:
        key=args[args.index('-p')+1];print(key+'='+values.get(key,''))
    elif any(arg.startswith('--property=') for arg in args):
        key=next(arg.split('=',1)[1] for arg in args if arg.startswith('--property='));print(key+'='+values.get(key,''))
    else:
        for key,value in values.items():print(key+'='+value)
else:
    raise SystemExit('Unsupported session fixture query')
