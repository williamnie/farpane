#!/usr/bin/env python3
"""Freeze the packaging inputs for an existing RPM; no compilation or installation."""
import argparse
import gzip
import json
import os
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Linux/packaging'))
import native_bundle as bundle
import native_deb


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rpm_receipt',type=Path)
    parser.add_argument('application_sources',type=Path)
    args=parser.parse_args()
    receipt=args.rpm_receipt.resolve(strict=True)
    sources=args.application_sources.resolve(strict=True)
    if (os.getuid()==0 or receipt.parent!=ROOT/'Build/Linux/rpm'
            or sources.parent!=ROOT/'Build/Linux/source-bundles' or not sources.name.endswith('.tar.gz')):
        raise ValueError('Expected generated RPM receipt and application source archive')
    record=json.loads(receipt.read_text())
    package=receipt.with_suffix('')
    if bundle.digest(package)!=record['sha256']:
        raise ValueError('RPM differs from packaging receipt')
    artifact=ROOT/'Build/Linux/artifacts'/record['artifact_id']
    bundle.verify(artifact)
    snapshot=sources.with_name(sources.name.removesuffix('.tar.gz'))
    manifest=json.loads((snapshot/'source-manifest.json').read_text())
    source_sha=bundle.digest(sources)
    if (manifest.get('gui_source_update',{}).get('artifact_id')!=record['artifact_id']
            or sources.with_suffix('.gz.sha256').read_text().split()[0]!=source_sha):
        raise ValueError('Application source archive binding differs')
    names=set(native_deb.TOOLS)|{
        'LICENSE','Scripts/linux/package-native-rpm.py','Scripts/linux/package-native-rpm-recipe.py',
        'Linux/packaging/native_rpm.py','Linux/packaging/native_deb.py',
        'Linux/packaging/native-rpm.spec.in','Linux/packaging/native-rpm-README.txt',
        'Linux/packaging/native-rpm-builder-fedora44.Dockerfile',
        'Linux/tests/native-runtime-images.lock.json','Linux/docs/native-install.md'}
    inputs={name:bundle.digest(ROOT/name) for name in sorted(names)}
    if {name:inputs[name] for name in native_deb.TOOLS}!=record['installer_sources']:
        raise ValueError('Installer sources differ from the actual RPM')
    label='farpane-native-rpm-recipe-'+record['version']
    if '/' in label or '..' in label:
        raise ValueError('Invalid recipe name')
    output=ROOT/'Build/Linux/source-bundles'
    target=output/label;archive=output/(label+'.tar.gz')
    if target.exists() or archive.exists():raise ValueError('Preserving frozen recipe outputs')
    with tempfile.TemporaryDirectory(prefix='.rpm-recipe-',dir=output) as temp:
        tree=Path(temp)/label;tree.mkdir()
        for name in names:
            dest=tree/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/name,dest)
            if bundle.digest(dest)!=inputs[name]:raise ValueError('Packaging input changed: '+name)
        proof={'schema':1,'kind':'farpane-native-rpm-recipe','rpm':package.name,'rpm_sha256':record['sha256'],
            'version':record['version'],'release':record['release'],'artifact_id':record['artifact_id'],
            'artifact_manifest_sha256':bundle.digest(artifact/'manifest.json'),
            'application_source_archive':sources.name,'application_source_sha256':source_sha,
            'files':inputs,'contains_application_source':False,'application_rebuilt':False}
        (tree/'recipe.json').write_text(json.dumps(proof,indent=2)+'\n')
        (tree/'README.md').write_text(
            '# FarPane RPM packaging inputs\n\n'
            'Use the frozen bundle named by recipe.json and the fixed builder image in the included lock. '
            'Place the bundle at Build/Linux/artifacts/ARTIFACT inside this extracted recipe directory.\n\n'
            'Run: python3 -B Scripts/linux/package-native-rpm.py Build/Linux/artifacts/ARTIFACT '
            '--version VERSION --release RELEASE\n\n'
            'Substitute the artifact, version and release from recipe.json. The command packages the existing '
            'GUI/core/media without compiling them or touching host services. '
            'The complete application source archive is separately identified and hashed in recipe.json.\n')
        tree.rename(target)
        with archive.open('xb') as raw,gzip.GzipFile(filename='',fileobj=raw,mode='wb',mtime=0) as compressed:
            with tarfile.open(fileobj=compressed,mode='w|') as tar:
                def normalize(info):
                    info.uid=info.gid=info.mtime=0;info.uname=info.gname='';info.pax_headers={}
                    info.mode=0o755 if info.isdir() or info.mode&0o111 else 0o644
                    return info
                tar.add(target,arcname=label,filter=normalize)
        sha=bundle.digest(archive);archive.with_suffix('.gz.sha256').write_text(sha+'  '+archive.name+'\n')
        print(json.dumps({'recipe':str(target),'archive':str(archive),'sha256':sha,'files':len(inputs)},indent=2))


if __name__=='__main__':main()
