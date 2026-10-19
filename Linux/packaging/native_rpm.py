"""Wrap a verified bundle without compiling, activating or running the app."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

import native_bundle
import native_deb

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = 'farpane-native-candidate'
PREFIX = Path('usr/lib64') / PACKAGE

# Translate the already validated ELF/API dependency set into Fedora providers.
# zlib's SONAME capability supports both zlib and zlib-ng-compat providers.
FEDORA = {
    'python3 (>= 3.11)': 'python3 >= 3.11', 'libsecret-1-0': 'libsecret',
    'libc6 (>= 2.39)': 'glibc >= 2.39', 'libgcc-s1': 'libgcc',
    'libstdc++6 (>= 5)': 'libstdc++', 'libegl1': 'libglvnd-egl',
    'libgles2': 'libglvnd-gles', 'libgbm1': 'mesa-libgbm',
    'libgtk-4-1 (>= 4.14)': 'gtk4 >= 4.14',
    'libadwaita-1-0 (>= 1.5)': 'libadwaita >= 1.5',
    'libpango-1.0-0': 'pango', 'libgraphene-1.0-0': 'graphene',
    'libglib2.0-0t64 (>= 2.80)': 'glib2 >= 2.80',
    'libx11-6': 'libX11', 'libxfixes3': 'libXfixes', 'libxtst6': 'libXtst',
    'libxkbcommon0': 'libxkbcommon', 'libxcb1': 'libxcb',
    'libxcb-shm0': 'libxcb', 'libxcb-randr0': 'libxcb',
    'libpulse0': 'pulseaudio-libs', 'libva2 (>= 2.20)': 'libva >= 2.20',
    'libva-drm2 (>= 2.20)': 'libva >= 2.20', 'libdrm2': 'libdrm',
    'libdbus-1-3': 'dbus-libs', 'zlib1g': 'libz.so.1()(64bit)',
    'libgstreamer1.0-0': 'gstreamer1',
    'libgstreamer-plugins-base1.0-0': 'gstreamer1-plugins-base',
}


def dependencies(artifact, record):
    debian = native_deb.dependencies(artifact, record)
    if any(d not in FEDORA for d in debian):
        raise ValueError('Undeclared Fedora ELF dependency mapping')
    return sorted({FEDORA[d] for d in debian})


def extract(package, target):
    """Extract only our expected prefixes into a fresh private directory."""
    names = subprocess.check_output(['rpm', '-qplp', str(package)], text=True).splitlines()
    roots = ('/' + str(PREFIX), '/usr/share/doc/' + PACKAGE, '/usr/share/licenses/' + PACKAGE)
    for name in names:
        if (not name.startswith('/') or '..' in Path(name).parts
                or any(ord(c) < 32 for c in name)
                or not (name in ('/usr/bin/farpane-maintenance', '/usr/bin/farpane-user-integration')
                        or any(name == prefix or name.startswith(prefix + '/') for prefix in roots))):
            raise ValueError('Unexpected RPM payload path')
    target.mkdir()
    with subprocess.Popen(['rpm2cpio', str(package)], stdout=subprocess.PIPE) as source:
        subprocess.run(['cpio', '--extract', '--make-directories', '--quiet', '--no-absolute-filenames'],
                       stdin=source.stdout, cwd=target, check=True, timeout=60)
        source.stdout.close()
        if source.wait(timeout=5):
            raise ValueError('RPM payload extraction failed')


def build(artifact, version, release, output):
    if not Path('/.dockerenv').is_file() or os.geteuid() == 0:
        raise ValueError('Use the isolated packaging container as an ordinary user')
    artifact = Path(artifact).resolve(strict=True)
    output = Path(output).resolve()
    if (not artifact.is_relative_to(ROOT / 'Build/Linux/artifacts')
            or not output.is_relative_to(ROOT / 'Build/Linux')
            or not re.fullmatch(r'[0-9][0-9A-Za-z.+~]*', version)
            or not re.fullmatch(r'[0-9][0-9A-Za-z._+]*', release)
            or any(c in str(output) for c in '\r\n%')):
        raise ValueError('Invalid RPM build inputs')
    manifest = native_bundle.verify(artifact)
    record = json.loads((artifact / 'build.json').read_text())
    library = (artifact / 'lib/libdrmtap.so.0').readlink()
    if set(record['packaged_binaries']) != {'farpane', 'libexec/farpane-core', 'lib/' + str(library)}:
        raise ValueError('Unexpected executable set')
    required = dependencies(artifact, record)
    tools = {name: native_bundle.digest(ROOT / name) for name in native_deb.TOOLS}
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.native-rpm-', dir=output) as temporary:
        top = Path(temporary)
        tree = top / 'SOURCES/root'
        payload = tree / PREFIX / 'payload'
        shutil.copytree(artifact, payload, symlinks=True)
        native_bundle.verify(payload)
        for name in native_deb.TOOLS:
            target = tree / PREFIX / 'control' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target); target.chmod(0o644)
            if native_bundle.digest(target) != tools[name]:
                raise ValueError('Installer source changed')
        for command, script in [('farpane-maintenance', 'install-native.py'),
                                ('farpane-user-integration', 'install-native-user.py')]:
            native_deb.write(tree, 'usr/bin/' + command, '#!/bin/sh\nexec /usr/bin/python3 -I -B /' +
                             str(PREFIX / 'control/Scripts/linux' / script) + ' "$@"\n', True)
        metadata = {'schema': 1, 'artifact_id': manifest['artifact_id'], 'version': version,
                    'release': release, 'runtime_ready': False, 'release_accepted': False,
                    'installer_sources': tools, 'requires': required,
                    'automatic_stage': False, 'automatic_activation': False,
                    'complete_license_source_audit': False}
        native_deb.write(tree, PREFIX / 'candidate.json', json.dumps(metadata, indent=2) + '\n')
        readme = (ROOT / 'Linux/packaging/native-rpm-README.txt').read_text()
        for key, value in [('VERSION', version), ('RELEASE', release), ('ARTIFACT', manifest['artifact_id'])]:
            readme = readme.replace('@' + key + '@', value)
        native_deb.write(tree, 'usr/share/doc/' + PACKAGE + '/README.RPM', readme)
        native_deb.write(tree, 'usr/share/doc/' + PACKAGE + '/native-install.md',
                         (ROOT / 'Linux/docs/native-install.md').read_text())
        native_deb.write(tree, 'usr/share/licenses/' + PACKAGE + '/LICENSE', (ROOT / 'LICENSE').read_text())
        spec = (ROOT / 'Linux/packaging/native-rpm.spec.in').read_text()
        for key, value in [('VERSION', version), ('RELEASE', release),
                           ('REQUIRES', '\n'.join('Requires: ' + dep for dep in required))]:
            spec = spec.replace('@' + key + '@', value)
        native_deb.write(tree, 'usr/share/doc/' + PACKAGE + '/package.spec', spec)
        spec_path = top / 'candidate.spec'; spec_path.write_text(spec)
        for path in [tree, *tree.rglob('*')]:
            if path.is_dir(): path.chmod(0o755)
            os.utime(path, (0, 0), follow_symlinks=False)
        subprocess.run(['rpmbuild', '-bb', '--define', '_topdir ' + str(top),
                        '--define', '_tmppath /tmp',
                        '--define', '_buildhost farpane-isolated', str(spec_path)],
                       env=dict(os.environ, SOURCE_DATE_EPOCH='0'), check=True, timeout=180)
        packages = list((top / 'RPMS').rglob('*.rpm'))
        if len(packages) != 1:
            raise ValueError('Expected exactly one RPM')
        package = packages[0]
        if subprocess.check_output(['rpm', '-qp', '--scripts', str(package)], text=True).strip():
            raise ValueError('Candidate must not have transaction scriptlets')
        unpacked = top / 'verified-payload'
        extract(package, unpacked)
        if native_bundle.verify(unpacked / PREFIX / 'payload') != manifest:
            raise ValueError('RPM changed the application payload')
        actual = json.loads((unpacked / PREFIX / 'candidate.json').read_text())
        if actual != metadata:
            raise ValueError('Candidate metadata changed')
        for name, digest in tools.items():
            if native_bundle.digest(unpacked / PREFIX / 'control' / name) != digest:
                raise ValueError('Packaged installer differs from canonical source')
        if native_bundle.verify(artifact) != manifest or tools != {
                name: native_bundle.digest(ROOT / name) for name in native_deb.TOOLS}:
            raise ValueError('Build inputs changed during packaging')
        filename = package.name
        digest = native_bundle.digest(package)
        target = output / filename
        if target.exists() or target.is_symlink():
            if target.is_symlink() or not target.is_file() or native_bundle.digest(target) != digest:
                raise ValueError('Refusing to overwrite a different RPM')
        else:
            os.link(package, target)
        checksum = target.with_suffix(target.suffix + '.sha256')
        contents = digest + '  ' + filename + '\n'
        if checksum.exists() or checksum.is_symlink():
            if checksum.is_symlink() or checksum.read_text() != contents:
                raise ValueError('Refusing to overwrite a different checksum')
        else:
            checksum.write_text(contents)
        return dict(metadata, package=str(target), sha256=digest, installed=False,
                    payload_verified=True, scriptlets=[])
