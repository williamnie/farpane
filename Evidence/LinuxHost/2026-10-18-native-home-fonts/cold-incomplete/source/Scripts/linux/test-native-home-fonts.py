#!/usr/bin/env python3
"""Run a bounded A/B/B/A font experiment with a frozen app and no host devices."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('fonts', type=Path)
    args = parser.parse_args()
    artifact, fonts = args.artifact.resolve(strict=True), args.fonts.resolve(strict=True)
    assert os.getuid() != 0 and artifact.parent == ROOT / 'Build/Linux/artifacts'
    parent = ROOT / 'Build/Linux/native-font-probe'
    assert fonts.parent == parent and fonts.name.startswith('fonts.')
    sys.path.insert(0, str(ROOT / 'Linux/packaging'))
    import native_bundle
    native_bundle.verify(artifact)
    probe = json.loads((fonts / 'probe.json').read_text())
    pin = json.loads((ROOT / 'Linux/tests/native-font-probe.lock.json').read_text())
    assert probe['pin'] == pin
    for item in probe['fonts']:
        assert hashlib.sha256((fonts / item['file']).read_bytes()).hexdigest() == item['sha256']
    output = Path(tempfile.mkdtemp(prefix='run-', dir=parent))
    sources = ['Linux/tests/' + name for name in ('native_host_smoke.py', 'native_viewer_smoke.py',
        'native_lifecycle_smoke.py', 'native_home_fonts.py', 'test_native_home_fonts_guard.py',
        'native-lifecycle-layout.json', 'native-font-probe.lock.json')]
    sources += ['Linux/packaging/native_bundle.py', 'Scripts/linux/test-native-home-fonts.py',
                'Scripts/linux/prepare-native-font-probe.py']
    hashes = {}
    for name in sources:
        path = output / 'source' / name; path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, path); hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    name = 'farpane-fonts-' + uuid.uuid4().hex[:12]
    artifact_inside = '/workspace/Build/Linux/artifacts/' + artifact.name
    command = ['docker', 'run', '--rm', '--name', name, '--network', 'none', '--read-only',
        '--cpus', '4', '--memory', '6g', '--pids-limit', '512', '--cap-drop', 'ALL',
        '--cap-add', 'CHOWN', '--cap-add', 'DAC_OVERRIDE', '--cap-add', 'FOWNER',
        '--cap-add', 'SETUID', '--cap-add', 'SETGID', '--security-opt', 'no-new-privileges',
        '--tmpfs', '/opt:rw,exec,mode=755,size=512m', '--tmpfs', '/tmp:rw,nosuid,nodev,mode=1777,size=256m',
        '--tmpfs', '/run/farpane-native-test:rw,nosuid,nodev,mode=755,size=256m',
        '--mount', f'type=bind,src={output}/source/Linux/tests,dst=/workspace/Linux/tests,readonly',
        '--mount', f'type=bind,src={output}/source/Linux/packaging,dst=/workspace/Linux/packaging,readonly',
        '--mount', f'type=bind,src={artifact},dst={artifact_inside},readonly',
        '--mount', f'type=bind,src={fonts},dst=/fonts,readonly',
        '--mount', f'type=bind,src={output},dst=/output',
        '-e', 'FARPANE_NATIVE_TEST_MODE=home-fonts', '-e', 'FARPANE_NATIVE_TEST_ARTIFACT=' + artifact_inside,
        '-e', 'HOME=/run/farpane-native-test/user', '-e', 'PYTHONDONTWRITEBYTECODE=1',
        '--entrypoint', 'timeout', pin['image'], '--signal=TERM', '--kill-after=10', '160',
        'python3', '-B', '/workspace/Linux/tests/native_viewer_smoke.py', '/output/run',
        str(os.getuid()), str(os.getgid())]
    inputs = {'image': pin['image'], 'artifact': artifact.name, 'fonts': str(fonts), 'sources': hashes,
              'manifest_sha256': hashlib.sha256((artifact / 'manifest.json').read_bytes()).hexdigest(),
              'font_config_sha256': hashlib.sha256((fonts / 'fonts.conf').read_bytes()).hexdigest(),
              'font_probe_sha256': hashlib.sha256((fonts / 'probe.json').read_bytes()).hexdigest(), 'command': command}
    (output / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
    print(output, flush=True)
    with (output / 'runner.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try: code = process.wait(timeout=180)
        finally:
            if process.poll() is None:
                subprocess.run(['docker', 'rm', '-f', name], stdout=log, stderr=subprocess.STDOUT,
                               timeout=10, check=False)
                process.wait(timeout=10)
    (output / 'exit.json').write_text(json.dumps({'returncode': code}) + '\n')
    if code: raise SystemExit(f'Font experiment failed ({code}); see {output}/runner.log')
    print((output / 'run/home-font-result.json').read_text(), flush=True)


if __name__ == '__main__':
    main()
