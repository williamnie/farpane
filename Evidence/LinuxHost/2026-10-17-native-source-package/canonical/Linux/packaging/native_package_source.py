"""Bind packaging to a completed source build without replacing product caches."""
import hashlib
import json
from pathlib import Path
import subprocess


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def identity(root):
    # Git would otherwise silently discover the enclosing checkout when an
    # extracted source snapshot happens to live under that checkout's Build/.
    if (root / '.git').exists():
        top = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'],
                                          cwd=root, text=True).strip()).resolve()
        if top != root.resolve():
            raise ValueError('Git metadata belongs to a different source root')
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
        return {'kind': 'git', 'head': head}
    manifest = root / 'source-manifest.json'
    data = json.loads(manifest.read_text())
    if data.get('schema') != 1 or data.get('kind') != 'farpane-native-source-snapshot':
        raise ValueError('Missing native source snapshot identity')
    return {'kind': 'source-snapshot', 'manifest_sha256': digest(manifest)}


def load(directory, canonical_sources):
    directory = Path(directory).resolve(strict=True)
    workspace = directory / 'workspace'
    result_path = directory / 'result.json'
    result = json.loads(result_path.read_text())
    if (result.get('result') != 'pass' or result.get('full_native_media_core_gui_build') is not True
            or result.get('network') != 'none' or result.get('cargo_cache_initially_empty') is not True
            or result.get('compiler_target_initially_empty') is not True
            or result.get('nonffmpeg_dependencies_freshly_built') is not True):
        raise ValueError('Expected a completed isolated source build')
    manifest_path = workspace / 'source-manifest.json'
    if digest(manifest_path) != result['source_manifest_sha256']:
        raise ValueError('Source build manifest changed')
    manifest = json.loads(manifest_path.read_text())
    before_path = workspace / 'binary-build-receipt.json'
    if digest(before_path) != manifest['files']['binary-build-receipt.json']['sha256']:
        raise ValueError('Original canonical source record changed')
    before = json.loads(before_path.read_text())['sources']
    if before != canonical_sources:
        raise ValueError('Packaging sources differ from the compiled application sources')
    for name, expected in before.items():
        if manifest['files'][name]['sha256'] != expected or digest(workspace / name) != expected:
            raise ValueError('Compiled canonical source changed: ' + name)
    for name, stage in result['stages'].items():
        if stage['returncode'] != 0 or digest(directory / (name + '.log')) != stage['log_sha256']:
            raise ValueError('Source build stage record changed: ' + name)
    if set(result['stages']) != {'ffmpeg', 'drmtap', 'core-release', 'gui-release'}:
        raise ValueError('Incomplete source build stages')
    build = workspace / 'Build/Linux'
    binaries = {'native-core': build / 'source-target/release/farpane-core',
                'native-gui': build / 'source-target/release/farpane'}
    if {name: digest(path) for name, path in binaries.items()} != result['binaries']:
        raise ValueError('Source build executables changed')
    components = {name: json.loads((directory / (name + '-build-info.json')).read_text())
                  for name in binaries}
    core, gui = components['native-core'], components['native-gui']
    if (core.get('component') != 'native-core' or core.get('gpu_host_compiled') is not True
            or core.get('legacy_ui') is not False or gui.get('component') != 'native-gui'
            or core.get('protocol') != gui.get('protocol')
            or core.get('runtime_ready') is not False or gui.get('runtime_ready') is not False):
        raise ValueError('Unexpected source build component capabilities')
    version = json.loads((workspace / 'Linux/dependencies.lock.json').read_text())['libdrmtap']['version']
    library_name = 'lib/libdrmtap.so.' + version
    library = build / 'drmtap-build' / Path(library_name).name
    if digest(library) != result['drmtap_sha256']:
        raise ValueError('Source build media library changed')
    if set(result['ffmpeg_static_sha256']) != {'avcodec', 'avutil', 'avformat', 'avfilter'}:
        raise ValueError('Unexpected FFmpeg archive set')
    for name, expected in result['ffmpeg_static_sha256'].items():
        if digest(build / 'vcpkg/installed/x64-linux/lib' / ('lib' + name + '.a')) != expected:
            raise ValueError('Source build FFmpeg archive changed: ' + name)
    receipt = {'schema': 1, 'sources': before, 'binaries': result['binaries'],
               'components': components, 'core_features': ['farpane-native', 'linux-gpu-media'],
               'offline': True, 'locked': True}
    inputs = {'farpane': binaries['native-gui'], 'libexec/farpane-core': binaries['native-core'],
              library_name: library}
    provenance = {'source_manifest_sha256': result['source_manifest_sha256'],
                  'source_build_result_sha256': digest(result_path),
                  'native_dependency_manifest_sha256': result['native_dependency_manifest_sha256'],
                  'builder_image': (directory / 'builder-image-id.txt').read_text().strip()}
    return receipt, inputs, provenance
