"""Scan package contents, including binaries and nested archives, without echoing secrets."""
import gzip
import hashlib
import io
import json
import lzma
import os
from pathlib import Path
import re
import socket
import subprocess
import tarfile
import zipfile

MAX_ENTRY = 512 * 1024 * 1024
MAX_TOTAL = 16 * 1024**3
# Cargo's pinned flate2 1.1.9 includes an intentionally undecodable gzip input.
# Its raw bytes are still scanned. Only this exact upstream fixture may remain
# opaque; an altered fixture or any other broken archive fails the scan.
OPAQUE_TEST_FIXTURES = {
    '083dd284aa1621916a2d0f66ea048c8d3ba7a722b22d0d618722633f51e7d39c',
}
# Unmodified vcpkg 9e593bb18ea69cc5095e012465dcd675a822ed0d contains a
# third-party directory name that coincides with a local machine-name rule.
# Require both the snapshot-relative path and the exact public Git bytes;
# any modification is scanned normally, and the exception remains in reports.
PUBLIC_SOURCE_COLLISIONS = {
    'native-dependencies/vcpkg/ports/sdl1/portfile.cmake':
        'e7fe3cb327048a43f679b751df2e8d54c18f83d18059370c8dda3c3ee68cf5c3',
}


def rules(pattern_file=None):
    values = []
    home = str(Path.home())
    local_home = home if home.startswith(('/home/', '/Users/')) else ''
    for value in (os.environ.get('USER', ''), socket.gethostname(), local_home):
        if len(value) >= 4 and value not in ('root', 'runner', 'user', '/root', '/home/runner', '/home/user'):
            values.append(('local-identity', re.escape(value)))
    try:
        addresses = subprocess.check_output(['ip', '-j', '-4', 'address'], stderr=subprocess.DEVNULL, text=True)
        for interface in json.loads(addresses):
            for address in interface.get('addr_info', []):
                value = address.get('local', '')
                if value.startswith(('10.', '192.168.')):
                    values.append(('local-address', re.escape(value)))
    except (OSError, subprocess.CalledProcessError, ValueError):
        pass
    configured = pattern_file or os.environ.get('FARPANE_PRIVACY_PATTERNS')
    filename = Path(configured) if configured else Path.home() / '.config/farpane-private-patterns'
    if configured and not filename.is_file():
        raise ValueError('Configured privacy rule file is missing')
    if filename.is_file():
        for number, pattern in enumerate(filename.read_text().splitlines(), 1):
            if pattern.strip() and not pattern.lstrip().startswith('#'):
                values.append(('private-rule-' + str(number), pattern))
    result = []
    for label, pattern in values:
        try:
            result.append((label, re.compile(pattern.encode())))
        except re.error:
            raise ValueError('Invalid privacy expression: ' + label) from None
    return result


class Scanner:
    def __init__(self, patterns):
        self.patterns = patterns
        self.files = 0
        self.bytes = 0
        self.hits = []
        self.opaque_fixtures = []
        self.public_source_collisions = []

    def safe_name(self, name):
        value = name.encode()
        for _, expression in self.patterns:
            value = expression.sub(b'<redacted>', value)
        return value.decode(errors='replace')

    def inspect(self, name, data, depth=0):
        if depth > 8 or len(data) > MAX_ENTRY:
            raise ValueError('Privacy scan archive/file limit exceeded')
        self.files += 1
        self.bytes += len(data)
        if self.bytes > MAX_TOTAL:
            raise ValueError('Privacy scan total size limit exceeded')
        matched = [label for label, expression in self.patterns
                   if expression.search(data) or expression.search(name.encode())]
        if matched:
            finding = {'file': self.safe_name(name), 'rules': sorted(set(matched))}
            public = any((name == suffix or name.endswith('/' + suffix) or name.endswith('!' + suffix))
                         and hashlib.sha256(data).hexdigest() == expected
                         for suffix, expected in PUBLIC_SOURCE_COLLISIONS.items())
            if public:
                self.public_source_collisions.append(finding)
            else:
                self.hits.append(finding)
        # Inspect decompressed bytes too; never rely on strings(1) or an outer checksum.
        stream = io.BytesIO(data)
        if data.startswith(b'!<arch>\n'):
            offset = 8
            while offset < len(data):
                header = data[offset:offset + 60]
                if len(header) != 60 or header[58:] != b'`\n':
                    raise ValueError('Invalid ar package')
                size = int(header[48:58])
                member = header[:16].decode().strip().rstrip('/')
                offset += 60
                if size < 0 or offset + size > len(data):
                    raise ValueError('Truncated ar package')
                self.inspect(name + '!' + member, data[offset:offset + size], depth + 1)
                offset += size + size % 2
        elif zipfile.is_zipfile(stream):
            with zipfile.ZipFile(stream) as archive:
                for entry in archive.infolist():
                    if not entry.is_dir():
                        if entry.file_size > MAX_ENTRY:
                            raise ValueError('ZIP member exceeds scan limit')
                        self.inspect(name + '!' + entry.filename, archive.read(entry), depth + 1)
        elif data.startswith((b'\x1f\x8b', b'\xfd7zXZ\x00')):
            checksum = hashlib.sha256(data).hexdigest()
            if checksum in OPAQUE_TEST_FIXTURES:
                self.opaque_fixtures.append({'file': self.safe_name(name), 'sha256': checksum})
                return
            expanded = (gzip.GzipFile(fileobj=io.BytesIO(data)) if data.startswith(b'\x1f\x8b')
                        else lzma.LZMAFile(io.BytesIO(data)))
            with expanded:
                self.inspect_stream(name, expanded, depth + 1)
        elif len(data) >= 512 and data[257:262] == b'ustar':
            self.inspect_tar(name, stream, depth + 1)
        elif data.startswith(b'\xed\xab\xee\xdb'):
            raise ValueError('Extract RPM payload with rpm2cpio, then scan the extracted directory')

    def inspect_stream(self, name, stream, depth):
        # Tar streams can exceed MAX_ENTRY in total while each member remains bounded.
        first = stream.read(512)
        if len(first) >= 512 and first[257:262] == b'ustar':
            class Prefixed:
                def __init__(self): self.prefix = io.BytesIO(first)
                def read(self, size):
                    data = self.prefix.read(size)
                    return data + stream.read(size - len(data))
            self.inspect_tar(name, Prefixed(), depth)
        else:
            rest = stream.read(MAX_ENTRY + 1 - len(first))
            self.inspect(name + '!decompressed', first + rest, depth)

    def inspect_tar(self, name, stream, depth):
        with tarfile.open(fileobj=stream, mode='r|') as archive:
            for entry in archive:
                member = name + '!' + entry.name
                if entry.isfile():
                    if entry.size > MAX_ENTRY:
                        raise ValueError('Tar member exceeds scan limit')
                    with archive.extractfile(entry) as content:
                        self.inspect(member, content.read(MAX_ENTRY + 1), depth + 1)
                elif entry.issym() or entry.islnk():
                    self.inspect(member, entry.linkname.encode(), depth + 1)
                elif not entry.isdir():
                    raise ValueError('Unexpected special file in scanned archive')

    def path(self, path):
        path = Path(path)
        if path.is_symlink():
            self.inspect(path.name, str(path.readlink()).encode())
        elif path.is_dir():
            for child in sorted(path.rglob('*')):
                name = child.relative_to(path).as_posix()
                if child.is_symlink():
                    self.inspect(name, str(child.readlink()).encode())
                elif child.is_file():
                    self.read_file(child, name)
                elif not child.is_dir():
                    raise ValueError('Unexpected special file in privacy scan')
        elif path.is_file():
            self.read_file(path, path.name)
        else:
            raise ValueError('Privacy scan input is missing')

    def read_file(self, path, name):
        if path.stat().st_size > MAX_ENTRY:
            # Large source archives are inspected incrementally, never skipped.
            if name.endswith(('.tar.gz', '.tgz', '.tar.xz', '.tar')):
                with tarfile.open(path, mode='r|*') as archive:
                    for entry in archive:
                        if entry.isfile():
                            if entry.size > MAX_ENTRY:
                                raise ValueError('Tar member exceeds scan limit')
                            self.inspect(name + '!' + entry.name, archive.extractfile(entry).read(MAX_ENTRY + 1), 1)
                        elif entry.issym() or entry.islnk():
                            self.inspect(name + '!' + entry.name, entry.linkname.encode(), 1)
                        elif not entry.isdir():
                            raise ValueError('Unexpected special file in scanned archive')
                return
            raise ValueError('Privacy scan file limit exceeded')
        self.inspect(name, path.read_bytes())

    def report(self):
        return {'result': 'fail' if self.hits else 'pass', 'files_scanned': self.files,
                'bytes_scanned': self.bytes, 'rule_count': len(self.patterns), 'findings': self.hits,
                'opaque_test_fixtures_scanned': self.opaque_fixtures,
                'verified_public_source_collisions': self.public_source_collisions}


def require_clean(path, pattern_file=None):
    scanner = Scanner(rules(pattern_file))
    scanner.path(path)
    if scanner.hits:
        raise ValueError('Package privacy scan failed: ' + json.dumps(scanner.report()))
    return scanner.report()
