from pathlib import Path
import concurrent.futures,hashlib,json,posixpath,urllib.request
R=Path('/home/xiaobei/Documents/xiaobei/farpane');O=R/'Build/Linux/legacy-notices'
registry=R/'Build/Linux/cargo/registry/src/index.crates.io-1949cf8c6b5b557f'
specs=[('dlopen_derive','0.1.4','szymonwieloch/rust-dlopen','26b70292744db1052403378d4a01075b6171e3d1','rust-dlopen-derive'),
 ('serial','0.4.0','dcuddeback/serial-rs','7ed6540c2789b7c7365cd7a89fcb7bac7c567de8','serial'),
 ('target_build_utils','0.3.1','nagisa/target_build_utils.rs','7ccd5c913b65fdc1cab1d96814b2e2c8cb432e91','')]
def request(url,path):
 if not path.exists():
  with urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'FarPane-pinned-source-check'}),timeout=25) as f:data=f.read(4*1024*1024+1)
  assert len(data)<=4*1024*1024;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
 return path.read_bytes()
def blob(data):return hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
def inspect(spec):
 name,version,repo,rev,prefix=spec;root=registry/(name+'-'+version)
 tree_path=O/'trees'/repo/rev
 tree=json.loads(request(f'https://api.github.com/repos/{repo}/git/trees/{rev}?recursive=1',tree_path));assert not tree['truncated']
 nodes={n['path']:n for n in tree['tree'] if n['type']=='blob'}
 def remote(path):
  data=request(f'https://raw.githubusercontent.com/{repo}/{rev}/{path}',O/'files'/repo/rev/path)
  assert blob(data)==nodes[path]['sha'];return data
 def resolve(path):
  chain=[]
  for _ in range(8):
   node=nodes[path]
   if node['mode']!='120000':return path,chain
   data=remote(path);link=data.decode();chain.append({'path':path,'target':link,'git_blob_sha1':node['sha']})
   assert not link.startswith('/')
   path=posixpath.normpath(posixpath.join(posixpath.dirname(path),link));assert not path.startswith('../')
  raise AssertionError('symlink depth')
 bindings=[];mismatches=[]
 for local in sorted(root.rglob('*')):
  assert not local.is_symlink()
  if not local.is_file():continue
  rel=local.relative_to(root).as_posix()
  if rel=='.cargo-ok' or (rel=='Cargo.toml' and (root/'Cargo.toml.orig').exists()):continue
  logical='/'.join(p for p in (prefix,'Cargo.toml' if rel=='Cargo.toml.orig' else rel) if p)
  resolved,chain=resolve(logical);data=local.read_bytes()
  if blob(data)!=nodes[resolved]['sha']:mismatches.append(rel)
  bindings.append({'local_path':rel,'upstream_path':logical,'resolved_upstream_path':resolved,
   'symlink_chain':chain,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'git_blob_sha1':nodes[resolved]['sha']})
 notices=[]
 for path,node in nodes.items():
  if '/' in path or not any(w in path.lower() for w in ('license','licence','copying')):continue
  data=remote(path);notices.append({'upstream_path':path,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),
   'git_blob_sha1':blob(data),'url':f'https://raw.githubusercontent.com/{repo}/{rev}/{path}',
   'cached':str((O/'files'/repo/rev/path).relative_to(R))})
 return {'name':name,'version':version,'repository':repo,'revision':rev,'package_path':prefix,
  'root':str(root.relative_to(R)),'published_files':bindings,'mismatches':mismatches,'notices':notices,'tree_sha256':hashlib.sha256(tree_path.read_bytes()).hexdigest()}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:results=list(pool.map(inspect,specs))
(O/'bindings.json').write_text(json.dumps(results,indent=2)+'\n')
for r in results:print(json.dumps({'name':r['name'],'published_files':len(r['published_files']),'mismatches':r['mismatches'],'notices':[n['upstream_path'] for n in r['notices']],'symlinks':[f['local_path'] for f in r['published_files'] if f['symlink_chain']]}))
