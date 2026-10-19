#!/usr/bin/env python3
"""Bind FarPane desktop entries and refresh their cache; never launch FarPane."""
import argparse
import json
import os
from pathlib import Path
import pwd
import sys

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Linux/packaging'))
from native_install import Store
from native_user_install import UserIntegration


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    commands=parser.add_subparsers(dest='command',required=True)
    bind=commands.add_parser('bind');bind.add_argument('release');bind.add_argument('--previous',required=True)
    commands.add_parser('recover');commands.add_parser('rollback')
    args=parser.parse_args()
    home=Path(pwd.getpwuid(os.getuid()).pw_dir)
    user=UserIntegration(Store(),home,data=os.environ.get('XDG_DATA_HOME') or None,
                         config=os.environ.get('XDG_CONFIG_HOME') or None,state=os.environ.get('XDG_STATE_HOME') or None)
    if args.command=='bind':result=user.bind(args.release,None if args.previous=='none' else args.previous)
    elif args.command=='recover':result=user.recover()
    else:result=user.rollback()
    # Entry commit/recovery is already durable. Cache failure must not pretend
    # to undo it, nor turn a retry of an idempotent bind into another migration.
    try:cache=user.refresh_desktop_cache()
    except (ValueError,PermissionError,OSError) as error:
        cache={'status':'failed','helper_started':False,'error':str(error)}
    result['application_processes_started']=result.pop('processes_started',False)
    result['processes_started']=cache['helper_started']
    result['desktop_cache']=cache
    print(json.dumps(result,indent=2))
    if cache['status'] not in ('refreshed','not-needed'):
        raise SystemExit(1)


if __name__=='__main__':main()
