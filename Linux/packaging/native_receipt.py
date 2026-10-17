"""Tie a completed offline build to its canonical sources and exact executables."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
BUILD=ROOT/'Build/Linux'
BINARIES={'native-core':'Build/Linux/target/release/farpane-core',
          'native-gui':'Build/Linux/native-target/release/farpane'}


def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()


def sources():
    files=[]
    for name in ('Linux/native','Linux/gui','Linux/src','Linux/patches'):
        for path in sorted((ROOT/name).rglob('*')):
            if '__pycache__' in path.parts:continue
            if path.is_symlink():raise ValueError('Unexpected canonical source symlink')
            if path.is_file():files.append(path)
    files.extend(ROOT/name for name in ('Linux/dependencies.lock.json','Linux/Cargo.lock'))
    return {p.relative_to(ROOT).as_posix():digest(p) for p in sorted(files)}


def verify(path):
    receipt=json.loads(path.read_text())
    if receipt.get('schema')!=1 or receipt.get('sources')!=sources():
        raise ValueError('Canonical sources changed since the recorded native build')
    if receipt.get('binaries')!={name:digest(ROOT/p) for name,p in BINARIES.items()}:
        raise ValueError('Native executables do not match their build receipt')
    return receipt


def finish(before,core_info,gui_info):
    source_state=json.loads(before.read_text())
    if source_state!=sources():raise ValueError('Canonical sources changed during build')
    core=json.loads(core_info.read_text());gui=json.loads(gui_info.read_text())
    if (core.get('component')!='native-core' or core.get('gpu_host_compiled') is not True
            or core.get('legacy_ui') is not False or gui.get('component')!='native-gui'
            or core.get('protocol')!=gui.get('protocol')
            or core.get('runtime_ready') is not False or gui.get('runtime_ready') is not False):
        raise ValueError('Unexpected built component capabilities')
    receipt={'schema':1,'sources':source_state,'binaries':{name:digest(ROOT/p) for name,p in BINARIES.items()},
             'components':{'native-core':core,'native-gui':gui},
             'core_features':['farpane-native','linux-gpu-media'],'offline':True,'locked':True}
    target=BUILD/'native-build.json';temporary=before.parent/'receipt.json'
    with temporary.open('x') as stream:stream.write(json.dumps(receipt,indent=2)+'\n')
    temporary.replace(target)
    verify(target)
    print(json.dumps({'receipt':str(target),'binaries':receipt['binaries']}))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation',choices=['snapshot','finish','verify'])
    parser.add_argument('paths',nargs='*',type=Path)
    args=parser.parse_args()
    if args.operation=='snapshot':print(json.dumps(sources(),indent=2))
    elif args.operation=='verify':print(json.dumps(verify(BUILD/'native-build.json'),indent=2))
    elif len(args.paths)==3:finish(*args.paths)
    else:parser.error('finish requires BEFORE CORE_INFO GUI_INFO')
