#!/usr/bin/env python3
"""Bind this user's FarPane menu/icons/D-Bus after system activation; never launch."""
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
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
