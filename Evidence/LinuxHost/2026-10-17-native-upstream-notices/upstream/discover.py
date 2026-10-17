from pathlib import Path
import concurrent.futures, hashlib, json, urllib.request, urllib.error

R=Path('/home/xiaobei/Documents/xiaobei/farpane')
O=R/'Build/Linux/upstream-notices'
report=json.loads((R/'Build/Linux/source-audit/native-source-audit-0558b85b9088b7fad3561b1b/report.json').read_text())
old=json.loads((R/'Linux/native-notice-supplements.json').read_text())
located={p['package_id'] for p in old['packages'] if p['full_package_notice_located']}
wanted={i['package'] for i in report['issues']} - located
packages=[]
for p in report['cargo_packages']:
    if p['id'] not in wanted:continue
    root=R/p['source_root'];vcs=Path(p['manifest']).parent/'.cargo_vcs_info.json'
    if not (R/vcs).is_file():continue
    v=json.loads((R/vcs).read_text())
    repo=p['repository']
    if p['name']=='dasp_sample':repo='https://github.com/RustAudio/dasp'
    if p['name']=='v4l2-sys-mit':repo='https://github.com/raymanfx/libv4l-rs'
    if p['name']=='zune-inflate':repo='https://github.com/etemesi254/zune-image'
    assert repo and repo.startswith('https://github.com/')
    repository=repo.removeprefix('https://github.com/').removesuffix('.git')
    packages.append(dict(package=p,repository=repository,revision=v['git']['sha1'],vcs_path=str(vcs),vcs=v))
(O/'packages.json').write_text(json.dumps(packages,indent=2)+'\n')

def fetch(entry):
    repository,revision=entry
    url=f'https://api.github.com/repos/{repository}/git/trees/{revision}?recursive=1'
    target=O/'trees'/repository/revision;target.parent.mkdir(parents=True,exist_ok=True)
    if target.is_file():data=json.loads(target.read_text())
    else:
        try:
            request=urllib.request.Request(url,headers={'User-Agent':'FarPane-pinned-source-material-check','Accept':'application/vnd.github+json'})
            with urllib.request.urlopen(request,timeout=25) as response:
                raw=response.read(4*1024*1024+1);assert len(raw)<=4*1024*1024
            data=json.loads(raw);target.write_bytes(raw)
        except Exception as e:return {'repository':repository,'revision':revision,'error':str(e)}
    assert not data.get('truncated')
    notices=[n for n in data['tree'] if n['type']=='blob' and any(w in Path(n['path']).name.lower() for w in ('license','licence','copying','notice','copyright'))]
    return {'repository':repository,'revision':revision,'url':url,'notices':notices,'tree_sha256':hashlib.sha256(target.read_bytes()).hexdigest()}

unique=sorted({(p['repository'],p['revision']) for p in packages})
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results=list(pool.map(fetch,unique))
(O/'discovery.json').write_text(json.dumps(results,indent=2)+'\n')
for r in results:print(json.dumps({k:v for k,v in r.items() if k!='notices'}|{'notices':[n['path'] for n in r.get('notices',[])]}))
