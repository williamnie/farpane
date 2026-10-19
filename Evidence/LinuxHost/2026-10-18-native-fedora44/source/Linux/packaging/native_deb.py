"""Build a Debian test candidate without changing a machine's active release."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

import native_bundle

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = 'farpane-native-candidate'
PREFIX = Path('usr/lib') / PACKAGE
TOOLS = (
    'Scripts/linux/install-native.py', 'Scripts/linux/install-native-user.py',
    'Scripts/linux/install-app.py', 'Linux/packaging/native_bundle.py',
    'Linux/packaging/native_install.py', 'Linux/packaging/native_install_runtime.py',
    'Linux/packaging/native_user_install.py',
)
# Direct ELF dependencies, including their supported API floors. Transitive
# dependencies remain owned by the distribution. Secret Service is dlopened.
LIBRARIES = {
    'ld-linux-x86-64.so.2': 'libc6 (>= 2.39)',
    'libc.so.6': 'libc6 (>= 2.39)', 'libm.so.6': 'libc6 (>= 2.39)',
    'libgcc_s.so.1': 'libgcc-s1', 'libstdc++.so.6': 'libstdc++6 (>= 5)',
    'libEGL.so.1': 'libegl1', 'libGLESv2.so.2': 'libgles2', 'libgbm.so.1': 'libgbm1',
    'libgtk-4.so.1': 'libgtk-4-1 (>= 4.14)',
    'libadwaita-1.so.0': 'libadwaita-1-0 (>= 1.5)',
    'libpango-1.0.so.0': 'libpango-1.0-0', 'libgraphene-1.0.so.0': 'libgraphene-1.0-0',
    'libglib-2.0.so.0': 'libglib2.0-0t64 (>= 2.80)',
    'libgobject-2.0.so.0': 'libglib2.0-0t64 (>= 2.80)',
    'libgio-2.0.so.0': 'libglib2.0-0t64 (>= 2.80)',
    'libX11.so.6': 'libx11-6', 'libXfixes.so.3': 'libxfixes3', 'libXtst.so.6': 'libxtst6',
    'libxkbcommon.so.0': 'libxkbcommon0', 'libxcb.so.1': 'libxcb1',
    'libxcb-shm.so.0': 'libxcb-shm0', 'libxcb-randr.so.0': 'libxcb-randr0',
    'libpulse.so.0': 'libpulse0', 'libpulse-simple.so.0': 'libpulse0',
    'libva.so.2': 'libva2 (>= 2.20)', 'libva-drm.so.2': 'libva-drm2 (>= 2.20)',
    'libdrm.so.2': 'libdrm2', 'libdbus-1.so.3': 'libdbus-1-3', 'libz.so.1': 'zlib1g',
    'libgstreamer-1.0.so.0': 'libgstreamer1.0-0',
    'libgstapp-1.0.so.0': 'libgstreamer-plugins-base1.0-0',
    'libgstvideo-1.0.so.0': 'libgstreamer-plugins-base1.0-0',
}


def dependencies(artifact, build):
    required = {'python3 (>= 3.11)', 'libsecret-1-0'}
    for name, recorded in build['packaged_binaries'].items():
        path = artifact / native_bundle.relative_path(name)
        header = subprocess.check_output(['readelf', '-h', str(path)], text=True)
        if not re.search(r'Machine:\s+Advanced Micro Devices X86-64', header):
            raise ValueError('Debian candidate requires x86_64 ELF: ' + name)
        dynamic = subprocess.check_output(['readelf', '-d', str(path)], text=True)
        needed = re.findall(r'\(NEEDED\).*\[([^\]]+)\]', dynamic)
        if needed != recorded['needed'] or native_bundle.digest(path) != recorded['sha256']:
            raise ValueError('ELF differs from package build record: ' + name)
        symbols = subprocess.check_output(['readelf', '--version-info', str(path)], text=True)
        for prefix, ceiling in [('GLIBC', (2, 39)), ('GLIBCXX', (3, 4, 21)), ('CXXABI', (1, 3, 9))]:
            versions = re.findall(r'\b' + prefix + r'_([0-9]+(?:\.[0-9]+)+)\b', symbols)
            if any(tuple(map(int, version.split('.'))) > ceiling for version in versions):
                raise ValueError('ELF exceeds the declared runtime baseline: ' + name + ' ' + prefix)
        for library in needed:
            if library not in LIBRARIES:
                raise ValueError('Undeclared Debian runtime dependency: ' + library)
            required.add(LIBRARIES[library])
    return sorted(required)


def write(root, name, text, executable=False):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755 if executable else 0o644)


def build(artifact, version, output):
    artifact = Path(artifact).resolve(strict=True)
    output = Path(output).resolve()
    if not output.is_relative_to(ROOT / 'Build/Linux'):
        raise ValueError('Debian output must be under Build/Linux')
    if not re.fullmatch(r'[0-9][0-9A-Za-z.+~\-]*', version):
        raise ValueError('Invalid candidate package version')
    subprocess.run(['dpkg', '--validate-version', version], check=True)
    manifest = native_bundle.verify(artifact)
    record = json.loads((artifact / 'build.json').read_text())
    library = (artifact / 'lib/libdrmtap.so.0').readlink()
    actual = set(record['packaged_binaries'])
    if actual != {'farpane', 'libexec/farpane-core', 'lib/' + str(library)}:
        raise ValueError('Unexpected packaged executable set')
    depends = dependencies(artifact, record)
    tool_hashes = {name: native_bundle.digest(ROOT / name) for name in TOOLS}
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.native-deb-', dir=output) as temporary:
        temporary = Path(temporary)
        tree = temporary / 'root'
        payload = tree / PREFIX / 'payload'
        shutil.copytree(artifact, payload, symlinks=True)
        native_bundle.verify(payload)
        control_root = tree / PREFIX / 'control'
        for name in TOOLS:
            target = control_root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
            target.chmod(0o644)
            if native_bundle.digest(target) != tool_hashes[name]:
                raise ValueError('Installer source changed during packaging')
        for name, script in [('farpane-maintenance', 'install-native.py'),
                             ('farpane-user-integration', 'install-native-user.py')]:
            write(tree, 'usr/bin/' + name, '#!/bin/sh\nexec /usr/bin/python3 -I -B /' +
                  str(PREFIX / 'control/Scripts/linux' / script) + ' "$@"\n', True)
        readme = (ROOT / 'Linux/packaging/native-deb-README.txt').read_text().replace(
            '@ARTIFACT@', manifest['artifact_id']).replace('@VERSION@', version)
        write(tree, 'usr/share/doc/' + PACKAGE + '/README.Debian', readme)
        shutil.copyfile(ROOT / 'LICENSE', tree / 'usr/share/doc' / PACKAGE / 'copyright')
        (tree / 'usr/share/doc' / PACKAGE / 'copyright').chmod(0o644)
        write(tree, PREFIX / 'candidate.json', json.dumps({
            'schema': 1, 'artifact_id': manifest['artifact_id'], 'version': version,
            'runtime_ready': False, 'release_accepted': False,
            'installer_sources': tool_hashes, 'depends': depends,
            'complete_license_source_audit': False,
        }, indent=2) + '\n')
        # The package manager owns only this candidate and its tools. Active
        # /opt releases are copies owned by the existing maintenance store.
        write(tree, 'DEBIAN/postinst', '#!/bin/sh\nset -eu\ncase "${1:-}" in\n'
              '  configure)\n    /usr/bin/farpane-maintenance stage /' + str(PREFIX / 'payload') + '\n'
              '    printf "%s\\n" "FarPane candidate staged; active service and desktop are unchanged."\n'
              '    printf "%s\\n" "See /usr/share/doc/' + PACKAGE + '/README.Debian for maintenance activation."\n'
              '    ;;\nesac\n', True)
        size = sum(p.lstat().st_size for p in tree.rglob('*') if p.is_file())
        write(tree, 'DEBIAN/control', '\n'.join([
            'Package: ' + PACKAGE, 'Version: ' + version, 'Architecture: amd64',
            'Section: net', 'Priority: optional',
            'Maintainer: FarPane contributors <noreply@users.noreply.github.com>',
            'Homepage: https://github.com/williamnie/farpane',
            'Installed-Size: ' + str((size + 1023) // 1024),
            'Depends: ' + ', '.join(depends),
            'Recommends: systemd, dbus-user-session, gnome-keyring',
            'Description: FarPane native remote desktop GUI test candidate',
            ' Includes the GTK4 GUI, native core, static FFmpeg, icons and maintenance tools.',
            ' Installation stages a candidate without changing the active service or desktop.',
            ' Activation requires an explicit maintenance window on a systemd desktop.',
            ' Removal retains activated releases, service configuration and user data.',
            ' This development candidate has not passed the complete release acceptance gates.', '',
        ]))
        for path in [tree, *tree.rglob('*')]:
            if path.is_dir():
                path.chmod(0o755)
            os.utime(path, (0, 0), follow_symlinks=False)
        package = temporary / (PACKAGE + '_' + version + '_amd64.deb')
        subprocess.run(['dpkg-deb', '--root-owner-group', '--threads-max=4', '-Zxz', '-z6',
                        '--build', str(tree), str(package)], check=True,
                       env=dict(os.environ, SOURCE_DATE_EPOCH='0'))
        if manifest != native_bundle.verify(artifact):
            raise ValueError('Bundle changed during Debian packaging')
        if tool_hashes != {name: native_bundle.digest(ROOT / name) for name in TOOLS}:
            raise ValueError('Installer sources changed during Debian packaging')
        digest = native_bundle.digest(package)
        target = output / package.name
        if target.exists() or target.is_symlink():
            if target.is_symlink() or not target.is_file() or native_bundle.digest(target) != digest:
                raise ValueError('Refusing to replace a different Debian package')
        else:
            os.link(package, target)
        checksum = target.with_suffix(target.suffix + '.sha256')
        value = digest + '  ' + target.name + '\n'
        if checksum.exists() or checksum.is_symlink():
            if checksum.is_symlink() or not checksum.is_file() or checksum.read_text() != value:
                raise ValueError('Refusing to replace a different Debian checksum')
        else:
            with checksum.open('x') as stream:
                stream.write(value)
        return {'package': str(target), 'sha256': digest, 'artifact_id': manifest['artifact_id'],
                'version': version, 'depends': depends, 'runtime_ready': False, 'installed': False}
