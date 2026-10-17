from pathlib import Path
import concurrent.futures, hashlib, json, urllib.request

R=Path('/home/user/farpane');O=R/'Build/Linux/upstream-notices'
packages=json.loads((O/'packages.json').read_text())
discoveries={(d['repository'],d['revision']):d for d in json.loads((O/'discovery.json').read_text())}

def sha(data):return hashlib.sha256(data).hexdigest()
def blob(data):return hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
def one(spec):
    repository,revision,path=spec
    tree=json.loads((O/'trees'/repository/revision).read_text())
    node=next(n for n in tree['tree'] if n['path']==path and n['type']=='blob')
    url=f'https://raw.githubusercontent.com/{repository}/{revision}/{path}'
    target=O/'files'/repository.lower()/revision/path;target.parent.mkdir(parents=True,exist_ok=True)
    if target.is_file():raw=target.read_bytes()
    else:
        request=urllib.request.Request(url,headers={'User-Agent':'FarPane-pinned-source-material-check'})
        with urllib.request.urlopen(request,timeout=25) as response:
            raw=response.read(1024*1024+1);assert len(raw)<=1024*1024
        assert blob(raw)==node['sha'] and len(raw)==node['size']
        target.write_bytes(raw)
    assert blob(raw)==node['sha'] and len(raw)==node['size']
    return dict(path=path,sha256=sha(raw),bytes=len(raw),git_blob_sha1=node['sha'],url=url,
                cached=str(target.relative_to(R)))

specs=set()
for p in packages:
    repository,revision=p['repository'],p['revision']
    notices=[n['path'] for n in discoveries[repository,revision]['notices'] if '/' not in n['path']]
    p['notices']=notices
    if not notices:continue
    folder=p['vcs'].get('path_in_vcs')
    if folder is None:folder=p['package']['name']
    p['folder']=folder
    p['upstream_manifest']='/'.join(n for n in (folder,'Cargo.toml') if n)
    p['source_probe']='/'.join(n for n in (folder,'src/lib.rs') if n)
    specs.update((repository,revision,n) for n in notices+[p['upstream_manifest'],p['source_probe']])
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results=list(pool.map(one,sorted(specs)))
files={r['url']:r for r in results}
(O/'downloads.json').write_text(json.dumps(results,indent=2)+'\n')
prepared=[]
for p in packages:
    if not p['notices']:continue
    def item(n):return files[f'https://raw.githubusercontent.com/{p["repository"]}/{p["revision"]}/{n}']
    m=R/p['package']['manifest'];local=m.with_name('Cargo.toml.orig')
    if not local.is_file():local=m
    remote=R/item(p['upstream_manifest'])['cached']
    probe=R/item(p['source_probe'])['cached'];local_probe=m.parent/'src/lib.rs'
    manifest_match=sha(local.read_bytes())==sha(remote.read_bytes())
    probe_match=sha(local_probe.read_bytes())==sha(probe.read_bytes())
    result=dict(name=p['package']['name'],version=p['package']['version'],manifest_match=manifest_match,source_probe_match=probe_match)
    print(json.dumps(result),flush=True)
    prepared.append({**p,**result,'local_original_manifest':str(local.relative_to(R)),
                     'local_source_probe':str(local_probe.relative_to(R)),
                     'upstream_files':[item(n) for n in p['notices']+[p['upstream_manifest'],p['source_probe']]]})
(O/'bindings.json').write_text(json.dumps(prepared,indent=2)+'\n')
