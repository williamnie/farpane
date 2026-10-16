#!/usr/bin/env python3
"""Install a verified FarPane bundle for this user without starting it or a service."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile


def verify(directory):
    manifest = json.loads((directory / 'manifest.json').read_text())
    declared = set()
    for entry in manifest['files']:
        relative = Path(entry['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Invalid artifact path: ' + str(relative))
        declared.add(str(relative))
        path = directory / relative
        if 'symlink' in entry:
            if not path.is_symlink() or str(path.readlink()) != entry['symlink']:
                raise ValueError('Symlink mismatch: ' + str(relative))
            path.resolve(strict=True).relative_to(directory.resolve())
        elif path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
            raise ValueError('File hash mismatch: ' + str(relative))
    actual = {str(p.relative_to(directory)) for p in directory.rglob('*') if p.is_file() or p.is_symlink()}
    if actual != declared | {'manifest.json'}:
        raise ValueError('Artifact contains undeclared files')
    if manifest.get('features') not in [
        ['flutter', 'hwcodec', 'drm', 'farpane-linux'],
        ['flutter', 'hwcodec', 'drm', 'farpane-linux', 'linux-gpu-media'],
    ]:
        raise ValueError('Unexpected application feature set')
    return manifest


def desktop_string(path):
    return str(path).replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%')


def install(artifact, user_home, system=False):
    manifest = verify(artifact)
    if system and verify(Path('/opt/farpane/current')) != manifest:
        raise ValueError('System and user artifacts differ')
    artifact_id = manifest['artifact_id']
    if not artifact_id.startswith('farpane-') or Path(artifact_id).name != artifact_id:
        raise ValueError('Invalid artifact ID')
    base = user_home / '.local/opt/farpane'
    destination = base / artifact_id
    current = base / 'current'
    launcher = user_home / '.local/share/applications/org.farpane.FarPane.desktop'
    launcher_marker = 'X-FarPane-Managed=true\n'
    if launcher.exists() and (launcher.is_symlink() or launcher_marker not in launcher.read_text()):
        raise ValueError('Refusing to overwrite an unmanaged desktop entry')
    if current.exists() or current.is_symlink():
        if not current.is_symlink() or not current.resolve().is_relative_to(base.resolve()):
            raise ValueError('Refusing to replace an unmanaged current path')
        verify(current.resolve())
    base.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if (destination / 'manifest.json').read_bytes() != (artifact / 'manifest.json').read_bytes():
            raise ValueError('Refusing to overwrite an existing release')
        verify(destination)
    else:
        with tempfile.TemporaryDirectory(dir=base, prefix='.install-') as temporary:
            staged = Path(temporary) / artifact_id
            shutil.copytree(artifact, staged, symlinks=True)
            verify(staged)
            staged.rename(destination)
    previous = str(current.readlink()) if current.is_symlink() else None
    with tempfile.TemporaryDirectory(dir=base, prefix='.switch-') as temporary:
        link = Path(temporary) / 'current'
        link.symlink_to(artifact_id)
        os.replace(link, current)
    launcher.parent.mkdir(parents=True, exist_ok=True)
    executable = Path('/opt/farpane/farpane') if system else current / 'farpane'
    launcher_text = (
        '[Desktop Entry]\nType=Application\nName=FarPane\n'
        'Comment=FarPane Linux development build\n'
        f'Exec="{desktop_string(executable)}"\n'
        'Terminal=false\nCategories=Network;RemoteAccess;\n'
        'StartupWMClass=Farpane\n' + launcher_marker
    )
    with tempfile.NamedTemporaryFile(mode='w', dir=launcher.parent, prefix='.farpane-', delete=False) as temporary:
        temporary.write(launcher_text)
        temporary_path = Path(temporary.name)
    temporary_path.chmod(0o644)
    os.replace(temporary_path, launcher)
    return {'installed': str(destination), 'executable': str(executable),
            'desktop_entry': str(launcher), 'previous': previous,
            'started': False, 'service_installed': False, 'stage': manifest['stage']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path)
    parser.add_argument('--system', action='store_true', help='Point the menu at the matching root-owned system bundle')
    args = parser.parse_args()
    if os.geteuid() == 0:
        raise SystemExit('Run this per-user installer as the desktop user')
    print(json.dumps(install(args.artifact.resolve(), Path.home(), args.system), indent=2))


if __name__ == '__main__':
    main()
