from pathlib import Path
import hashlib,json,re,subprocess,tarfile,tempfile
root=Path.cwd();ref=Path('/home/user/services/rustdesk-host-perf-20261015');lock=json.loads((root/'Linux/dependencies.lock.json').read_text());vcpkg=ref/'vcpkg';rd=ref/'rustdesk'
def git(repo,*args):return subprocess.check_output(['git','-c','safe.directory='+str(repo),'-C',str(repo),*args])
def sha(path,algorithm='sha256'):
 with path.open('rb') as f:return hashlib.file_digest(f,algorithm).hexdigest()
ports={}
for name in ('aom','libvpx','libyuv','opus','mfx-dispatch','libjpeg-turbo','ffnvcodec','vcpkg-cmake','vcpkg-cmake-config','vcpkg-cmake-get-vars','vcpkg-pkgconfig-get-modules','vcpkg-tool-meson','pkgconf'):
 if name in ('aom','libvpx','libyuv','opus','mfx-dispatch'):
  origin='rustdesk';repo=rd;path='res/vcpkg/'+name;tree=git(repo,'rev-parse',lock[origin]['commit']+':'+path).decode().strip()
 else:
  origin='vcpkg';repo=vcpkg;path='ports/'+name;tree=git(repo,'rev-parse',lock[origin]['commit']+':'+path).decode().strip()
 if name=='ffnvcodec':tree='95b6f37a43dab098bf4be5c84e15e47a86cf7960'
 abi_path=root/'Build/Linux/vcpkg/installed/x64-linux/share'/name/'vcpkg_abi_info.txt'
 abi={line.split()[0]:line.split()[1] for line in abi_path.read_text().splitlines() if len(line.split())==2}
 files={}
 for entry in git(repo,'ls-tree','-r',tree).decode().splitlines():
  meta,n=entry.split('\t');mode,kind,oid=meta.split();assert kind=='blob'
  data=git(repo,'cat-file','blob',oid);digest=hashlib.sha256(data).hexdigest();files[n]=digest
  assert n in abi and abi[n]==digest,(name,n,'ABI mismatch')
 ports[name]={'origin':origin,'git_tree':tree,'files':files,'abi_record_sha256':sha(abi_path)}

def tar_index(stream):
 with tarfile.open(fileobj=stream,mode='r:*') as archive:
  result={}
  for item in archive:
   if item.isdir():continue
   assert item.isfile() or item.issym(),item.name
   if item.isfile():h=hashlib.file_digest(archive.extractfile(item),'sha256').hexdigest();value=['file',item.mode,h]
   else:value=['symlink',item.mode,item.linkname]
   assert item.name not in result;result[item.name]=value
  return result
archives=[]
for port,name in [('aom','aom-03087864cf4bea6abb0d28f95cf7843511413d8f.tar.gz'),('libyuv','libyuv-0faf8dd0e004520a61a603a4d2996d5ecc80dc3f.tar.gz'),('libvpx','webmproject-libvpx-v1.15.2.tar.gz'),('opus','xiph-opus-v1.5.2.tar.gz'),('mfx-dispatch','lu-zero-mfx_dispatch-1.35.1.tar.gz'),('mfx-dispatch','fix-missing-cstdint-import-d6241243f85a0d947bdfe813006686a930edef24.patch'),('libjpeg-turbo','libjpeg-turbo-libjpeg-turbo-3.2.0.tar.gz'),('ffnvcodec','FFmpeg-nv-codec-headers-n12.1.14.0.tar.gz'),('pkgconf','pkgconf-pkgconf-pkgconf-3.0.3.tar.gz'),('vcpkg-tool-meson','meson-1.9.0.tar.gz')]:
 source=vcpkg/'downloads'/name;entry={'port':port,'filename':name,'sha256':sha(source),'bytes':source.stat().st_size}
 if port in ('aom','libyuv'):
  commit=re.search(r'[0-9a-f]{40}',name).group();repo=vcpkg/'downloads/git-tmp'
  with tempfile.TemporaryFile() as original,source.open('rb') as cached:
   subprocess.run(['git','-c','safe.directory='+str(repo),'-C',str(repo),'archive',commit],stdout=original,check=True)
   original.seek(0);assert tar_index(original)==tar_index(cached),name
  entry['verified_git_commit']=commit
 else:
  repo=rd if ports[port]['origin']=='rustdesk' else vcpkg
  text=git(repo,'show',ports[port]['git_tree']+':portfile.cmake').decode()
  if port=='vcpkg-tool-meson':text=git(vcpkg,'show',ports[port]['git_tree']+':vcpkg-port-config.cmake').decode()
  value=sha(source,'sha512');assert value in text,(name,'SHA512 missing from pinned recipe')
  entry['verified_recipe_sha512']=value
 archives.append(entry)
result={'schema':1,'description':'Exact cached non-FFmpeg source/recipe materials, verified against pinned Git objects and vcpkg build ABI records. FFmpeg/AMF pins remain in dependencies.lock.json.','ports':ports,'archives':archives}
(root/'Build/Linux/gui-work/native-source-pins-proposal.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'ports':len(ports),'recipe_files':sum(len(p['files']) for p in ports.values()),'archives':len(archives),'proof':'all recipe files match cached ABI, two archives match complete pinned Git exports, other archives match pinned SHA512'}))
