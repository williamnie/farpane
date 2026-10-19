#!/usr/bin/env python3
"""Probe packaged executables in an owned container, then run actual GTK/video."""
import json
import os
import platform
from pathlib import Path
import shutil
import subprocess
import sys

assert os.geteuid()==0 and Path('/.dockerenv').is_file()
assert not Path('/dev/dri').exists()
assert not os.environ.get('DISPLAY') and not os.environ.get('WAYLAND_DISPLAY')
sys.path.insert(0,'/workspace/Linux/packaging')
import native_bundle

artifact=Path(os.environ['FARPANE_NATIVE_TEST_ARTIFACT']).resolve(strict=True)
assert artifact.is_relative_to(Path('/workspace/Build/Linux/artifacts'))
manifest=native_bundle.verify(artifact)
output=Path(sys.argv[1]);uid=int(sys.argv[2]);gid=int(sys.argv[3])
output.mkdir(parents=True);os.chown(output,uid,gid)
(output/'os-release.txt').write_bytes(Path('/etc/os-release').read_bytes())
distribution = platform.freedesktop_os_release()['ID']
if distribution in ('ubuntu', 'debian'):
    package_query = ['dpkg-query', '-W']
elif distribution == 'fedora':
    package_query = ['rpm', '-qa', '--qf', '%{NAME}\t%{VERSION}-%{RELEASE}.%{ARCH}\n']
else:
    raise AssertionError('Unsupported runtime fixture distribution: ' + distribution)
packages=subprocess.check_output(package_query,text=True)
(output/'runtime-packages.txt').write_text(packages)
release=Path('/opt/farpane-package-test/releases/probe')
shutil.copytree(artifact,release,symlinks=True)
native_bundle.verify(release)
core=release/'libexec/farpane-core';gui=release/'farpane'
private=Path('/run/farpane-native-test/probe');private.mkdir(parents=True,mode=0o755)
env=dict(os.environ,XDG_RUNTIME_DIR=str(private),XDG_CONFIG_HOME=str(private/'config'),
         XDG_DATA_HOME=str(private/'data'),XDG_STATE_HOME=str(private/'state'),XDG_CACHE_HOME=str(private/'cache'))
checks=[]
def probe(path,arg,user=False,ok=True,extra=None):
    command=[str(path),arg]
    if user:command=['setpriv','--reuid',str(uid),'--regid',str(gid),'--clear-groups',*command]
    result=subprocess.run(command,env=env|dict(extra or {}),capture_output=True,text=True,timeout=15)
    assert (result.returncode==0)==ok,(arg,user,result.stdout,result.stderr)
    return json.loads(result.stdout) if ok else result.stderr

core_info=probe(core,'--build-info');gui_info=probe(gui,'--build-info')
assert core_info['component']=='native-core' and core_info['gpu_host_compiled'] and not core_info['legacy_ui']
assert gui_info['component']=='native-gui' and core_info['protocol']==gui_info['protocol']==1
assert core_info['runtime_ready'] is False and gui_info['runtime_ready'] is False
checks.append('headless_build_probes')
alias=release/'lib/libdrmtap.so.0';library=alias.resolve()
expected_version=json.loads((release/'dependencies.lock.json').read_text())['libdrmtap']['version']
for user in (False,True):
    info=probe(core,'--check-bundled-media',user)
    assert '.'.join(map(str,info['libdrmtap_version']))==expected_version and info['device_opened'] is False
checks.append('same_release_media_root_and_user')
fallback=Path('/opt/farpane/lib');fallback.mkdir(parents=True)
shutil.copy2(library,fallback/'libdrmtap.so.0')
name=alias.readlink();alias.unlink()
for user in (False,True):
    probe(core,'--check-bundled-media',user,False,{'LD_LIBRARY_PATH':str(fallback)})
checks.append('missing_library_no_installed_or_search_fallback')
alias.symlink_to(fallback/'libdrmtap.so.0')
for user in (False,True):probe(core,'--check-bundled-media',user,False)
checks.append('cross_release_alias_rejected')
alias.unlink();alias.symlink_to(name)
library.chmod(0o666)
for user in (False,True):probe(core,'--check-bundled-media',user,False)
library.chmod(0o755)
checks.append('writable_library_rejected')
libdir=release/'lib';libdir.rename(release/'lib-retained');libdir.symlink_to(release/'lib-retained',target_is_directory=True)
for user in (False,True):probe(core,'--check-bundled-media',user,False)
libdir.unlink();(release/'lib-retained').rename(libdir)
checks.append('symlink_library_directory_rejected')
native_bundle.verify(release)
assert not list(private.iterdir()),'Diagnostic probes accessed configuration/runtime state'
checks.append('probes_leave_configuration_and_runtime_untouched')
dependencies={}
for path in (core,gui,library):
    result=subprocess.run(['ldd',str(path)],capture_output=True,text=True,check=True,timeout=15)
    assert 'not found' not in result.stdout and '/workspace/' not in result.stdout,result.stdout
    assert not any(name in result.stdout for name in ['libgtk-3','libgdk-3','libflutter','libsciter','libappindicator'])
    if path==core:assert 'libgtk-4' not in result.stdout and 'libadwaita' not in result.stdout
    dependencies[path.relative_to(release).as_posix()]=result.stdout
checks.append('resolved_elf_closure_no_build_or_legacy_gui_dependencies')
(output/'package-result.json').write_text(json.dumps({'result':'pass','checks':checks,'artifact':manifest['artifact_id'],
    'core':core_info,'gui':gui_info,'dependencies':dependencies,'gpu':False,'host_modified':False,
    'distribution':distribution,'package_query':package_query},indent=2)+'\n')
print(json.dumps({'package_checks':checks}),flush=True)
os.environ['FARPANE_NATIVE_TEST_MODE']='video'
from native_viewer_smoke import setup
setup(output/'viewer',uid,gid)
