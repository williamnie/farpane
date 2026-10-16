#!/usr/bin/env python3
"""Stage a root-owned FarPane bundle and disabled unit; never start/enable/reload services."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('user_installer', ROOT / 'Scripts/linux/install-app.py')
user_installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(user_installer)
MARKER = 'FarPane managed system installation v1\n'


def replace_link(base, name, target):
    with tempfile.TemporaryDirectory(dir=base, prefix='.link-') as temporary:
        path = Path(temporary) / name
        path.symlink_to(target)
        os.replace(path, base / name)


def stage(artifact, base, units):
    manifest = user_installer.verify(artifact)
    artifact_id = manifest['artifact_id']
    if not artifact_id.startswith('farpane-') or Path(artifact_id).name != artifact_id:
        raise ValueError('Invalid artifact ID')
    if base.is_symlink() or (base.exists() and
            (not (base / '.managed').is_file() or (base / '.managed').read_text() != MARKER)):
        raise ValueError('Refusing an unmanaged system installation directory')
    for name, expected in [('lib', 'current/lib'), ('farpane', 'current/farpane')]:
        path = base / name
        if (path.exists() or path.is_symlink()) and (not path.is_symlink() or str(path.readlink()) != expected):
            raise ValueError('Refusing an unmanaged system entry: ' + str(path))
    current = base / 'current'
    if current.exists() or current.is_symlink():
        if not current.is_symlink() or not current.resolve().is_relative_to((base / 'releases').resolve()):
            raise ValueError('Refusing an unmanaged current release')
        user_installer.verify(current.resolve())
    unit = units / 'farpane.service'
    unit_text = (ROOT / 'Linux/packaging/farpane.service').read_text()
    if unit.is_symlink() or (unit.exists() and not unit.read_text().startswith('# X-FarPane-Managed=true\n')):
        raise ValueError('Refusing an unmanaged FarPane service unit')
    base.mkdir(mode=0o755, parents=True, exist_ok=True)
    (base / '.managed').write_text(MARKER)
    releases = base / 'releases'
    if releases.is_symlink():
        raise ValueError('Release directory must not be a symlink')
    releases.mkdir(mode=0o755, exist_ok=True)
    destination = releases / artifact_id
    if destination.exists():
        user_installer.verify(destination)
        if (destination / 'manifest.json').read_bytes() != (artifact / 'manifest.json').read_bytes():
            raise ValueError('Refusing to replace a different installed release')
    else:
        with tempfile.TemporaryDirectory(dir=releases, prefix='.install-') as temporary:
            staged = Path(temporary) / artifact_id
            shutil.copytree(artifact, staged, symlinks=True)
            user_installer.verify(staged)
            for path in [staged, *staged.rglob('*')]:
                if path.is_symlink():
                    continue
                path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)
            staged.rename(destination)
    previous = str(current.readlink()) if current.is_symlink() else None
    replace_link(base, 'current', 'releases/' + artifact_id)
    replace_link(base, 'lib', 'current/lib')
    replace_link(base, 'farpane', 'current/farpane')
    units.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=units, prefix='.farpane-', delete=False) as temporary:
        temporary.write(unit_text)
        path = Path(temporary.name)
    path.chmod(0o644)
    os.replace(path, unit)
    return {'installed': str(destination), 'executable': str(base / 'farpane'),
            'unit': str(unit), 'previous': previous, 'started': False, 'enabled': False,
            'daemon_reload': False, 'maintenance_window_required': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('This staging installer requires root; it never starts a service')
    for parent in (Path('/opt'), Path('/etc/systemd/system')):
        metadata = parent.stat()
        if parent.is_symlink() or metadata.st_uid != 0 or metadata.st_mode & 0o022:
            raise SystemExit('Untrusted installation parent: ' + str(parent))
    base = Path('/opt/farpane')
    if base.exists():
        for path in [base, *base.rglob('*')]:
            metadata = path.lstat()
            if metadata.st_uid != 0 or (not path.is_symlink() and metadata.st_mode & 0o022):
                raise SystemExit('System release is writable by an untrusted user: ' + str(path))
    print(json.dumps(stage(args.artifact.resolve(), Path('/opt/farpane'),
                           Path('/etc/systemd/system')), indent=2))


if __name__ == '__main__':
    main()
