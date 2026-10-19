#!/usr/bin/env python3
"""Stage/inspect a native release; activate or recover only in a maintenance window."""
import argparse
import importlib.util
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Linux/packaging'))
from native_install import Store
from native_install_runtime import Coordinator,Systemd

spec=importlib.util.spec_from_file_location('legacy_installer',ROOT/'Scripts/linux/install-app.py')
legacy=importlib.util.module_from_spec(spec);spec.loader.exec_module(legacy)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    commands=parser.add_subparsers(dest='command',required=True)
    stage=commands.add_parser('stage');stage.add_argument('artifact',type=Path)
    for action in ('plan','activate'):
        command=commands.add_parser(action);command.add_argument('release')
        command.add_argument('--expect-current',required=True,help='Exact previous release ID, or none for first install')
        if action=='activate':
            command.add_argument('--maintenance-window',action='store_true')
            command.add_argument('--start-service',action='store_true')
    recover=commands.add_parser('recover');recover.add_argument('--maintenance-window',action='store_true')
    args=parser.parse_args();store=Store();runtime=Coordinator(store,Systemd(store),legacy.verify)
    if args.command=='stage':result=store.stage(args.artifact.absolute())
    elif args.command=='recover':result=runtime.recover(maintenance=args.maintenance_window)
    else:
        expected=None if args.expect_current=='none' else args.expect_current
        if args.command=='plan':
            with store.locked(read_only=True):result=runtime.preflight(args.release,expected)
        else:result=runtime.apply(args.release,expected_current=expected,maintenance=args.maintenance_window,start=args.start_service)
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
