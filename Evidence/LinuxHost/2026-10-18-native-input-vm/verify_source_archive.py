import hashlib,json,pathlib,tarfile
base=pathlib.Path(__file__).resolve().parent
raw=(base/'source-package.log').read_text();info=json.loads(raw[raw.rfind('\n{')+1:])
(base/'source-package.json').write_text(json.dumps(info,indent=2)+'\n')
archive=pathlib.Path(info['archive']);snapshot=pathlib.Path(info['snapshot']);manifest=json.loads((snapshot/'source-manifest.json').read_text())
with archive.open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==info['sha256']
seen=set()
with tarfile.open(archive,mode='r|gz') as tar:
 for member in tar:
  name=pathlib.PurePosixPath(member.name)
  assert name.parts[0]==snapshot.name and '..' not in name.parts
  rel=pathlib.PurePosixPath(*name.parts[1:]).as_posix()
  if member.isdir():continue
  assert rel not in seen;seen.add(rel)
  if rel=='source-manifest.json':
   assert json.load(tar.extractfile(member))==manifest;continue
  expected=manifest['files'][rel]
  if member.issym():assert expected=={'symlink':member.linkname}
  else:
   assert member.isfile() and member.size==expected['bytes']
   assert bool(member.mode&0o111)==expected['executable']
   assert hashlib.file_digest(tar.extractfile(member),'sha256').hexdigest()==expected['sha256'],rel
assert seen==set(manifest['files'])|{'source-manifest.json'}
result={'result':'pass','archive_sha256':info['sha256'],'verified_entries':len(manifest['files']),'vendor_packages':info['vendor_packages'],'fresh_full_build':False}
(base/'source-archive-verification.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
