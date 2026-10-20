#!/usr/bin/env python3
"""Build only Rust GUI changes against a verified frozen candidate's protocol.

The core, FFmpeg, dependency locks and paused worktree patches are never built.
All copied sources, logs and the new executable remain in a new Build directory.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Linux/packaging'))
import native_bundle as bundle


def source_map(root):
    return {str(p.relative_to(root)): bundle.digest(p) for p in sorted(root.rglob('*'))
            if p.is_file() and '__pycache__' not in p.parts}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('base', type=Path)
    args = parser.parse_args()
    base = args.base.resolve(strict=True)
    if os.getuid() == 0 or base.parent != ROOT / 'Build/Linux/artifacts':
        raise ValueError('Use an existing frozen artifact as an ordinary user')
    manifest = bundle.verify(base)
    build = json.loads((base / 'build.json').read_text())
    if build.get('gui_update'):
        raise ValueError('Use the original compiled GUI as the baseline')
    for name, sha in build['build_receipt']['sources'].items():
        path = base / ('dependencies.lock.json' if name == 'Linux/dependencies.lock.json' else 'source/' + name)
        if bundle.digest(path) != sha:
            raise ValueError('Frozen compiled source changed: ' + name)
    before = source_map(base / 'source/Linux/gui')
    after = source_map(ROOT / 'Linux/gui')
    changes = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))
    # Stylesheets are compiled into the GUI executable's GResource bundle.
    if not changes or any(not (k.startswith('src/') and k.endswith('.rs'))
                          and not (k.startswith('resources/') and k.endswith('.css'))
                          for k in changes):
        raise ValueError('This incremental path permits only GUI Rust source and stylesheet changes')
    parent = ROOT / 'Build/Linux/gui-updates'
    parent.mkdir(exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    source = output / 'source'
    shutil.copytree(ROOT / 'Linux/gui', source / 'Linux/gui')
    shutil.copytree(base / 'source/Linux/native/protocol', source / 'Linux/native/protocol')
    shutil.copyfile(Path(__file__), output / Path(__file__).name)
    pin = json.loads((base / 'dependencies.lock.json').read_text())['native_builder']
    workdir = '/workspace/' + str((source / 'Linux/gui').relative_to(ROOT))
    command = ['docker', 'run', '--rm', '--network', 'none', '--cpus', '4', '--memory', '12g',
        '--pids-limit', '512', '--user', f'{os.getuid()}:{os.getgid()}',
        '--mount', f'type=bind,src={ROOT},dst=/workspace,readonly',
        '--mount', f'type=bind,src={ROOT}/Build/Linux/native-target,dst=/workspace/Build/Linux/native-target',
        '--mount', f'type=bind,src={ROOT}/Build/Linux/cargo,dst=/workspace/Build/Linux/cargo',
        '-e', 'CARGO_HOME=/workspace/Build/Linux/cargo',
        '-e', 'CARGO_TARGET_DIR=/workspace/Build/Linux/native-target', '-e', 'CARGO_BUILD_JOBS=4',
        '-e', 'PATH=/workspace/Build/Linux/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
        '--workdir', workdir, '--entrypoint', '/workspace/Build/Linux/toolchain/bin/cargo', pin['image']]
    receipt = {'schema': 1, 'base_artifact': base.name,
        'base_manifest_sha256': bundle.digest(base / 'manifest.json'),
        'base_build_sha256': bundle.digest(base / 'build.json'), 'builder': pin,
        'changed_gui_sources': changes, 'sources': source_map(source),
        'recipe_sha256': bundle.digest(Path(__file__)), 'commands': [],
        'core_rebuilt': False, 'media_rebuilt': False, 'offline': True, 'locked': True}
    (output / 'inputs.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(output, flush=True)
    for phase, arguments in [('test', ['test', '--offline', '--locked']),
                             ('release', ['build', '--offline', '--locked', '--release'])]:
        with (output / (phase + '.log')).open('w') as log:
            result = subprocess.run(command + arguments, stdout=log, stderr=subprocess.STDOUT, timeout=1800)
        # 构建记录会随源码公开；保留命令结构，隐藏本机构建根目录。
        public_command = [part.replace(str(ROOT), '/home/user/farpane') for part in command + arguments]
        receipt['commands'].append({'phase': phase, 'command': public_command,
            'returncode': result.returncode, 'log_sha256': bundle.digest(output / (phase + '.log'))})
        (output / 'progress.json').write_text(json.dumps(receipt, indent=2) + '\n')
        if result.returncode:
            raise SystemExit(f'{phase} failed; see {output}')
    executable = output / 'farpane'
    shutil.copy2(ROOT / 'Build/Linux/native-target/release/farpane', executable)
    if source_map(source) != receipt['sources'] or source_map(ROOT / 'Linux/gui') != after:
        raise ValueError('GUI sources changed during compilation')
    if bundle.verify(base) != manifest:
        raise ValueError('Frozen parent changed during GUI compilation')
    receipt['binary_sha256'] = bundle.digest(executable)
    (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'result': 'pass', 'output': str(output),
                      'binary_sha256': receipt['binary_sha256'], 'changes': changes}), flush=True)


if __name__ == '__main__':
    main()
