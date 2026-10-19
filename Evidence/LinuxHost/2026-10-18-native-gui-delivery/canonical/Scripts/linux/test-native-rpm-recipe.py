#!/usr/bin/env python3
"""Reproduce an RPM using only an extracted frozen recipe and verified bundle."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Linux/packaging'))
import native_bundle as bundle


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive',type=Path)
    parser.add_argument('sha256')
    args=parser.parse_args()
    archive=args.archive.resolve(strict=True)
    if (os.getuid()==0 or archive.parent!=ROOT/'Build/Linux/source-bundles'
            or bundle.digest(archive)!=args.sha256):
        raise ValueError('Use the verified frozen recipe archive as an ordinary user')
    parent=ROOT/'Build/Linux/rpm-recipe-check';parent.mkdir(exist_ok=True)
    output=Path(tempfile.mkdtemp(prefix='run-',dir=parent));print(output,flush=True)
    with tarfile.open(archive) as tar:
        members=tar.getmembers();roots={Path(m.name).parts[0] for m in members}
        if (len(roots)!=1 or not next(iter(roots)).startswith('farpane-native-rpm-recipe-')
                or sum(m.size for m in members)>16*1024*1024):
            raise ValueError('Unexpected RPM recipe archive')
        tar.extractall(output,filter='data')
    workspace=output/roots.pop();proof=json.loads((workspace/'recipe.json').read_text())
    for name,sha in proof['files'].items():
        bundle.relative_path(name)
        if bundle.digest(workspace/name)!=sha:raise ValueError('Recipe source differs: '+name)
    artifact=ROOT/'Build/Linux/artifacts'/proof['artifact_id'];bundle.verify(artifact)
    if bundle.digest(artifact/'manifest.json')!=proof['artifact_manifest_sha256']:
        raise ValueError('Frozen bundle identity differs from recipe')
    target=workspace/'Build/Linux/artifacts'/artifact.name
    target.parent.mkdir(parents=True);shutil.copytree(artifact,target,symlinks=True)
    # The copied launcher derives ROOT from the extracted recipe. Its container
    # therefore receives only this workspace and its own output, not this repo.
    command=['python3','-B',str(workspace/'Scripts/linux/package-native-rpm.py'),str(target),
             '--version',proof['version'],'--release',proof['release']]
    (output/'invocation.json').write_text(json.dumps({'archive':str(archive),'sha256':args.sha256,'command':command},indent=2)+'\n')
    with (output/'console.log').open('w') as log:
        result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=300)
    (output/'exit.json').write_text(json.dumps({'exit':result.returncode})+'\n')
    if result.returncode:raise SystemExit(result.returncode)
    reproduced=workspace/'Build/Linux/rpm'/proof['rpm']
    sha=bundle.digest(reproduced)
    if sha!=proof['rpm_sha256']:raise ValueError('Standalone recipe produced different RPM bytes')
    for name,expected in proof['files'].items():
        if bundle.digest(workspace/name)!=expected:raise ValueError('Recipe input was modified')
    bundle.verify(target)
    report={'result':'pass','archive_sha256':args.sha256,'rpm_sha256':sha,
            'files_verified':len(proof['files']),'artifact_id':proof['artifact_id'],
            'byte_identical_rpm':True,'original_repository_mounted':False,
            'application_rebuilt':False,'host_installed':False}
    (output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report),flush=True)


if __name__=='__main__':main()
