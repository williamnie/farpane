#!/usr/bin/env python3
"""Stage canonical native crates without overwriting unrecognized build edits."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'Build/Linux'
MANIFEST = BUILD / 'native-source-map.json'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def destination(relative):
    parts = PurePosixPath(relative).parts
    if not parts or '..' in parts or PurePosixPath(relative).is_absolute():
        raise RuntimeError(f'Invalid staging path: {relative}')
    if parts[0] != 'gui' and parts[:2] not in (('native', 'protocol'), ('native', 'files')):
        raise RuntimeError(f'Unexpected staging prefix: {relative}')
    target = BUILD
    for part in parts:
        target = target / part
        if target.is_symlink():
            raise RuntimeError(f'Preserving unexpected staging symlink: {target}')
    return target


def main(check=False):
    old = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}
    sources = {}
    for relative in ('gui', 'native/protocol', 'native/files'):
        origin = ROOT / 'Linux' / relative
        if not origin.exists():
            continue
        for source in sorted(origin.rglob('*')):
            if source.is_symlink():
                raise RuntimeError(f'Unexpected canonical symlink: {source}')
            if not source.is_file():
                continue
            if 'target' in source.relative_to(origin).parts:
                raise RuntimeError('Native build outputs belong under Build/Linux')
            sources[str(source.relative_to(ROOT / 'Linux'))] = source.read_bytes()
    expected = {k: digest(v) for k, v in sources.items()}
    if check:
        if old != expected:
            raise RuntimeError('Native source map differs from canonical sources; stage before building')
        for relative, data in sources.items():
            target = destination(relative)
            if not target.is_file() or target.read_bytes() != data:
                raise RuntimeError(f'Native canonical/staged source mismatch: {target}')
        print(f'Verified {len(sources)} canonical native files (read only)')
        return
    # Validate the entire operation before writing any destination.
    for relative, data in sources.items():
        target = destination(relative)
        if target.exists() and target.read_bytes() != data:
            if digest(target.read_bytes()) != old.get(relative):
                raise RuntimeError(f'Preserving unknown generated edit: {target}')
    for relative in old.keys() - sources.keys():
        target = destination(relative)
        if target.exists() and digest(target.read_bytes()) != old[relative]:
            raise RuntimeError(f'Preserving unknown removed-source edit: {target}')
    for relative, data in sources.items():
        target = destination(relative)
        if not target.exists() or target.read_bytes() != data:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    for relative in old.keys() - sources.keys():
        destination(relative).unlink(missing_ok=True)
    MANIFEST.write_text(json.dumps(expected, indent=2) + '\n')
    print(f'Staged {len(sources)} canonical native files')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Verify staged sources and locks without writing')
    main(parser.parse_args().check)
