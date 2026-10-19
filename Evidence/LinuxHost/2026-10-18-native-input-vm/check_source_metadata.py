import os,json,pathlib,subprocess
root=pathlib.Path.cwd();base=root/'Build/Linux/native-input-vm';info=json.loads((base/'source-package.json').read_text());snapshot=pathlib.Path(info['snapshot']);assert snapshot.is_relative_to(root/'Build/Linux/source-bundles')
output=base/'source-metadata';output.mkdir()
lock=json.loads((root/'Linux/dependencies.lock.json').read_text())
code='''set -e
mkdir /output/home
cargo metadata --offline --locked --filter-platform x86_64-unknown-linux-gnu --manifest-path Build/Linux/src/rustdesk/Cargo.toml --no-default-features --features farpane-native,linux-gpu-media --format-version 1 > /output/core.json
cargo metadata --offline --locked --filter-platform x86_64-unknown-linux-gnu --manifest-path Build/Linux/gui/Cargo.toml --format-version 1 > /output/gui.json
'''
args=['docker','run','--rm','--network','none','--cpus','4','--memory','12g','--pids-limit','512','--user',f'{os.getuid()}:{os.getgid()}',
 '--mount',f'type=bind,src={snapshot},dst=/inputs/source,readonly',
 '--mount',f'type=bind,src={root}/Build/Linux/toolchain,dst=/toolchain,readonly',
 '--mount',f'type=bind,src={output},dst=/output',
 '-e','CARGO_HOME=/output/cargo','-e','CARGO_TARGET_DIR=/output/target','-e','HOME=/output/home','-e','PATH=/toolchain/bin:/usr/local/bin:/usr/bin:/bin',
 '--workdir','/inputs/source','--entrypoint','bash',lock['native_builder']['image'],'-c',code]
subprocess.run(args,check=True,timeout=90)
graphs={}
for key in ['core','gui']:
 data=json.loads((output/(key+'.json')).read_text());assert all(pathlib.PurePosixPath(p['manifest_path']).is_relative_to('/inputs/source') for p in data['packages']);graphs[key]=len(data['packages'])
assert not (output/'cargo/registry').exists() and not (output/'cargo/git').exists()
result={'result':'pass','graphs':graphs,'network':'none','compiler_invoked':False,'repository_mounted':False,'old_cargo_cache_mounted':False,'all_packages_inside_snapshot':True}
(base/'source-metadata-verification.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
