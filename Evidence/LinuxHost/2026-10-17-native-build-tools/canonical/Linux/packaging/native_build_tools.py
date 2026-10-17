"""Fetch pinned build tools and install a relocatable Rust SDK in a container."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request


def digest(path, algorithm='sha256'):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, algorithm).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_lock(path):
    lock = json.loads(path.read_text())
    require(lock['schema'] == 1 and lock['target'] == 'x86_64-unknown-linux-gnu',
            'Unsupported tools lock')
    require(set(lock['tools']) == {'rustc', 'cargo', 'rust-std', 'vcpkg', 'cmake'},
            'Unexpected tools')
    for tool in lock['tools'].values():
        require(Path(tool['filename']).name == tool['filename'] and
                tool['filename'] not in ('.', '..'), 'Invalid cache filename')
        require(tool['algorithm'] in ('sha256', 'sha512'), 'Invalid hash algorithm')
        require(len(tool['digest']) == hashlib.new(tool['algorithm']).digest_size * 2 and
                all(c in '0123456789abcdef' for c in tool['digest']), 'Invalid pinned hash')
        require(0 < tool['max_bytes'] <= 512 * 1024**2, 'Invalid download limit')
        url = urllib.parse.urlsplit(tool['url'])
        require(url.scheme == 'https' and not url.username and not url.password,
                'Tools require a public HTTPS URL')
    return lock


def verify_file(path, pin):
    require(path.is_file() and not path.is_symlink(), 'Missing or linked cached tool: ' + str(path))
    require(path.stat().st_size <= pin['max_bytes'] and
            digest(path, pin['algorithm']) == pin['digest'], 'Tool hash mismatch: ' + str(path))


class HTTPSRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        require(urllib.parse.urlsplit(newurl).scheme == 'https', 'Refusing HTTPS downgrade')
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def fetch(lock, cache, offline=False):
    cache.mkdir(parents=True, exist_ok=True)
    report = {}
    opener = urllib.request.build_opener(HTTPSRedirect())
    for name, pin in lock['tools'].items():
        target = cache / pin['filename']
        reused = target.exists() or target.is_symlink()
        if not reused:
            require(not offline, 'Offline cache missing: ' + str(target))
            print('Fetching pinned ' + name, flush=True)
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(dir=cache, prefix='.download-', delete=False) as output:
                    temporary = Path(output.name)
                    with opener.open(pin['url'], timeout=30) as response:
                        size = 0
                        while chunk := response.read(1024**2):
                            size += len(chunk)
                            require(size <= pin['max_bytes'], 'Download exceeds pinned size limit')
                            output.write(chunk)
                verify_file(temporary, pin)
                # Atomic creation cannot overwrite another download or user file.
                os.link(temporary, target)
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
        verify_file(target, pin)
        report[name] = {'path': str(target), 'sha256': digest(target),
                        'bytes': target.stat().st_size, 'cache_reused': reused}
    return report


def inventory(root):
    files = {}
    for path in sorted(root.rglob('*')):
        name, mode = path.relative_to(root).as_posix(), path.lstat().st_mode
        if name == 'toolchain-receipt.json':
            continue
        if stat.S_ISREG(mode):
            files[name] = {'sha256': digest(path), 'bytes': path.stat().st_size,
                           'executable': bool(mode & 0o111)}
        elif stat.S_ISLNK(mode):
            require(not path.readlink().is_absolute() and path.resolve(strict=True).is_relative_to(root),
                    'Unsafe SDK symlink: ' + name)
            files[name] = {'symlink': str(path.readlink())}
        else:
            require(stat.S_ISDIR(mode), 'Unexpected SDK file type')
    return files


def verify_sdk(sdk, lock_path):
    receipt = json.loads((sdk / 'toolchain-receipt.json').read_text())
    require(receipt['schema'] == 1 and receipt['kind'] == 'farpane-rust-sdk' and
            receipt['lock_sha256'] == digest(lock_path), 'SDK provenance mismatch')
    require(inventory(sdk) == receipt['files'], 'SDK inventory changed')
    return receipt


def install():
    require(Path('/.dockerenv').is_file() and os.geteuid() != 0, 'Use the unprivileged wrapper')
    require(not Path('/dev/dri').exists(), 'SDK preparation needs no GPU')
    lock_path = Path('/inputs/tools.lock.json')
    lock = read_lock(lock_path)
    output, cache = Path('/output'), Path('/inputs/cache')
    sdk = output / 'sdk'
    require(not sdk.exists(), 'Refusing to overwrite an SDK')
    work = output / 'unpacked'
    work.mkdir()
    for name in ('rustc', 'cargo', 'rust-std'):
        pin = lock['tools'][name]
        archive = cache / pin['filename']
        verify_file(archive, pin)
        package_root = pin['filename'].removesuffix('.tar.xz')
        with tarfile.open(archive) as stream:
            members = stream.getmembers()
            require(sum(m.size for m in members) <= 2 * 1024**3 and
                    all(Path(m.name).parts[0] == package_root for m in members), 'Unexpected SDK archive')
            stream.extractall(work, filter='data')
        with (output / (name + '-install.log')).open('w') as log:
            subprocess.run(['bash', str(work / package_root / 'install.sh'),
                            '--prefix=' + str(sdk), '--disable-ldconfig'],
                           stdout=log, stderr=subprocess.STDOUT, timeout=120, check=True)
    versions = {}
    for name in ('rustc', 'cargo'):
        version = subprocess.check_output([str(sdk / 'bin' / name), '--version'], text=True).strip()
        require(version.startswith(name + ' ' + lock['rust_version'] + ' '), 'Wrong installed tool version')
        versions[name] = version
    receipt = {'schema': 1, 'kind': 'farpane-rust-sdk', 'lock_sha256': digest(lock_path),
               'target': lock['target'], 'versions': versions, 'files': inventory(sdk),
               'compiled_from_source': False, 'network': 'none', 'host_installed': False}
    (sdk / 'toolchain-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    verify_sdk(sdk, lock_path)
    # Only these extracted SDK packages belong to this invocation.
    shutil.rmtree(work)
    print(json.dumps({'result': 'pass', 'sdk': str(sdk), 'versions': versions,
                      'receipt_sha256': digest(sdk / 'toolchain-receipt.json'),
                      'files': len(receipt['files'])}), flush=True)


if __name__ == '__main__':
    require(sys.argv[1:] == ['install'], 'Use prepare-native-tools.py for fetching')
    install()
