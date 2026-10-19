"""Integrity contract for native development bundles; never activates a release."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat

SCHEMA = 1
FEATURES = ['farpane-native', 'linux-gpu-media']
REQUIRED = {
    'farpane', 'libexec/farpane-core', 'lib/libdrmtap.so.0',
    'share/applications/org.farpane.FarPane.desktop',
    'share/dbus-1/services/org.farpane.FarPane.service',
    'share/icons/hicolor/scalable/apps/org.farpane.FarPane.svg',
    'share/icons/hicolor/1024x1024/apps/org.farpane.FarPane.png',
    'systemd/farpane.service', 'build.json', 'dependencies.lock.json',
    'README.txt', 'licenses/FarPane.txt',
}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def relative_path(name):
    if not isinstance(name, str) or not name or len(name) > 512:
        raise ValueError('Invalid bundle path')
    path = PurePosixPath(name)
    if (path.is_absolute() or str(path) != name or '\\' in name
            or any(p in ('', '.', '..') for p in path.parts)
            or any(ord(c) < 32 or ord(c) == 127 for c in name)):
        raise ValueError('Invalid bundle path: ' + name)
    return path


def file_index(directory):
    entries = []
    for path in sorted(directory.rglob('*')):
        name = path.relative_to(directory).as_posix()
        relative_path(name)
        mode = path.lstat().st_mode
        if stat.S_ISDIR(mode):
            if stat.S_IMODE(mode) != 0o755:
                raise ValueError('Unexpected bundle directory mode: ' + name)
            continue
        if name == 'manifest.json':
            continue
        if stat.S_ISLNK(mode):
            target = str(path.readlink())
            # The sole alias is local to lib/, with no directory traversal.
            if (name != 'lib/libdrmtap.so.0' or not re.fullmatch(r'libdrmtap\.so\.0\.\d+\.\d+', target)
                    or path.resolve(strict=True).parent != (directory / 'lib').resolve()
                    or not path.resolve(strict=True).is_file()):
                raise ValueError('Unexpected bundle symlink: ' + name)
            entries.append({'path': name, 'symlink': target})
        elif stat.S_ISREG(mode):
            permissions = stat.S_IMODE(mode)
            if permissions not in (0o644, 0o755) or path.stat().st_nlink != 1:
                raise ValueError('Unexpected bundle file permissions/links: ' + name)
            entries.append({'path': name, 'mode': permissions, 'bytes': path.stat().st_size, 'sha256': digest(path)})
        else:
            raise ValueError('Unexpected bundle file type: ' + name)
    return entries


def identifier(entries):
    canonical = json.dumps({'schema': SCHEMA, 'features': FEATURES, 'files': entries},
                           sort_keys=True, separators=(',', ':')).encode()
    return 'farpane-native-dev-' + hashlib.sha256(canonical).hexdigest()[:24]


def seal(directory):
    entries = file_index(directory)
    manifest = {
        'schema': SCHEMA, 'kind': 'farpane-native', 'artifact_id': identifier(entries),
        'features': FEATURES, 'runtime_ready': False, 'release_accepted': False,
        'files': entries,
    }
    path = directory / 'manifest.json'
    with path.open('x') as stream:
        stream.write(json.dumps(manifest, indent=2) + '\n')
    path.chmod(0o644)
    verify(directory)
    return manifest


def verify(directory, *, allow_private=False):
    directory = Path(directory)
    allowed = (0o700, 0o755) if allow_private else (0o755,)
    if directory.is_symlink() or not directory.is_dir() or stat.S_IMODE(directory.stat().st_mode) not in allowed:
        raise ValueError('Expected a regular bundle directory')
    path = directory / 'manifest.json'
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 4 * 1024 * 1024:
        raise ValueError('Invalid native manifest')
    if stat.S_IMODE(path.stat().st_mode) != 0o644 or path.stat().st_nlink != 1:
        raise ValueError('Invalid native manifest permissions/links')
    manifest = json.loads(path.read_text())
    if (set(manifest) != {'schema', 'kind', 'artifact_id', 'features', 'runtime_ready', 'release_accepted', 'files'}
            or manifest['schema'] != SCHEMA or manifest['kind'] != 'farpane-native'
            or manifest['features'] != FEATURES or manifest['runtime_ready'] is not False
            or manifest['release_accepted'] is not False):
        raise ValueError('Unsupported native development manifest')
    entries = manifest['files']
    if not isinstance(entries, list) or len(entries) > 4096:
        raise ValueError('Invalid manifest file index')
    names = []
    for entry in entries:
        name = entry.get('path') if isinstance(entry, dict) else None
        relative_path(name)
        if name == 'manifest.json':
            raise ValueError('Manifest cannot include itself')
        names.append(name)
    if len(set(names)) != len(names) or not REQUIRED <= set(names):
        raise ValueError('Missing or duplicate bundle entries')
    for executable in ('farpane', 'libexec/farpane-core'):
        if not any(e.get('path') == executable and e.get('mode') == 0o755 for e in entries):
            raise ValueError('Missing native executable')
    if entries != file_index(directory) or manifest['artifact_id'] != identifier(entries):
        raise ValueError('Native bundle contents/identity mismatch')
    return manifest
