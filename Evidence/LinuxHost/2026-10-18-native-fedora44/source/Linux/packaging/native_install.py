"""Root-owned release storage and recoverable offline switching.

Stage never changes current, units, running processes or user configuration.
Switching requires an independently verified stopped service/process set; the
runtime coordinator owns quiescing and restarting. No shell commands here.
"""
from contextlib import contextmanager
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile

import native_bundle

MARKER = 'FarPane managed system installation v1\n'
ID = re.compile(r'farpane-[a-z0-9]+(?:-[a-z0-9]+)*\Z')
MAX_FILE = 256 * 1024 * 1024
MAX_TOTAL = 512 * 1024 * 1024


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)


def secure_path(path, *, directory=False):
    """Reject untrusted ancestors before any root mutation."""
    path = Path(path)
    if not path.is_absolute(): raise ValueError('Installation paths must be absolute')
    for ancestor in reversed(path.parents):
        metadata = ancestor.lstat()
        if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != 0
                or metadata.st_mode & 0o022):
            raise ValueError('Untrusted installation ancestor: ' + str(ancestor))
    if path.exists() or path.is_symlink():
        metadata = path.lstat()
        if (metadata.st_uid != 0 or metadata.st_mode & 0o022
                or (directory and not stat.S_ISDIR(metadata.st_mode))
                or (not directory and not stat.S_ISREG(metadata.st_mode))):
            raise ValueError('Untrusted installation entry: ' + str(path))


def atomic_file(path, data, mode=0o644):
    secure_path(path)
    fd, temporary = tempfile.mkstemp(prefix='.farpane-write-', dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, path); sync_dir(path.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def link(path, target):
    with tempfile.TemporaryDirectory(prefix='.farpane-link-', dir=path.parent) as temporary:
        candidate = Path(temporary)/'link'; candidate.symlink_to(target)
        os.replace(candidate, path)
    sync_dir(path.parent)


def regular_bytes(path, limit=4*1024*1024):
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > limit:
            raise ValueError('Invalid regular metadata file')
        with os.fdopen(os.dup(fd), 'rb') as stream: data = stream.read(limit + 1)
        if len(data) > limit: raise ValueError('Metadata grew beyond limit')
        return data
    finally: os.close(fd)


@contextmanager
def directory_fd(path):
    """Open every component without following a mutable source directory link."""
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts: raise ValueError('Expected absolute directory')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in path.parts[1:]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd); fd = child
        yield fd
    finally: os.close(fd)


@contextmanager
def parent_fd(root_fd, relative):
    parts = native_bundle.relative_path(relative).parts
    fd = os.dup(root_fd)
    try:
        for component in parts[:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd); fd = child
        yield fd, parts[-1]
    finally: os.close(fd)


def source_names(root_fd):
    names=set();visited=0
    def walk(fd,prefix,depth):
        nonlocal visited
        if depth>32:raise ValueError('Source tree is too deep')
        for name in os.listdir(fd):
            visited+=1
            if visited>8192:raise ValueError('Source tree exceeds entry limit')
            relative=prefix+name;native_bundle.relative_path(relative)
            mode=os.stat(name,dir_fd=fd,follow_symlinks=False).st_mode
            if stat.S_ISDIR(mode):
                child=os.open(name,os.O_RDONLY|os.O_DIRECTORY|os.O_CLOEXEC|os.O_NOFOLLOW,dir_fd=fd)
                try:walk(child,relative+'/',depth+1)
                finally:os.close(child)
            elif stat.S_ISREG(mode) or stat.S_ISLNK(mode):names.add(relative)
            else:raise ValueError('Unexpected source object')
    walk(root_fd,'',0)
    return names


def copy_bundle(source, destination):
    """Pin the manifest, copy through anchored FDs, then verify the root copy."""
    with directory_fd(source) as source_fd:
        fd = os.open('manifest.json', os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source_fd)
        with os.fdopen(fd, 'rb') as stream:
            metadata = os.fstat(stream.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 4*1024*1024:
                raise ValueError('Invalid source manifest')
            raw = stream.read(4*1024*1024+1)
        manifest = json.loads(raw)
        # Structural and hash checks below reject malformed fields and content;
        # the final verifier enforces the complete canonical manifest contract.
        entries = manifest.get('files')
        if not isinstance(entries, list) or len(entries)>4096: raise ValueError('Invalid file index')
        names=set(); total=0
        for entry in entries:
            name=entry.get('path') if isinstance(entry,dict) else None
            native_bundle.relative_path(name)
            if name in names or name=='manifest.json': raise ValueError('Duplicate/reserved file path')
            names.add(name)
            if 'symlink' in entry:
                if (set(entry)!={'path','symlink'} or name!='lib/libdrmtap.so.0'
                        or not isinstance(entry['symlink'],str)
                        or not re.fullmatch(r'libdrmtap\.so\.0\.\d+\.\d+',entry['symlink'])):
                    raise ValueError('Invalid media alias')
            else:
                if (set(entry)!={'path','mode','bytes','sha256'} or type(entry['bytes']) is not int
                        or not 0<=entry['bytes']<=MAX_FILE or entry['mode'] not in (0o644,0o755)
                        or not isinstance(entry['sha256'],str) or not re.fullmatch('[0-9a-f]{64}',entry['sha256'])):
                    raise ValueError('Invalid file descriptor')
                total+=entry['bytes']
        if total>MAX_TOTAL: raise ValueError('Bundle exceeds installation limit')
        if source_names(source_fd)!=names|{'manifest.json'}:raise ValueError('Undeclared/missing source entry')
        destination.mkdir(mode=0o755)
        for entry in entries:
            target=destination/entry['path'];target.parent.mkdir(parents=True,exist_ok=True,mode=0o755)
            with parent_fd(source_fd,entry['path']) as (parent,name):
                if 'symlink' in entry:
                    if os.readlink(name,dir_fd=parent)!=entry['symlink']: raise ValueError('Source alias changed')
                    target.symlink_to(entry['symlink']);continue
                fd=os.open(name,os.O_RDONLY|os.O_CLOEXEC|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
                with os.fdopen(fd,'rb') as incoming, target.open('xb') as outgoing:
                    metadata=os.fstat(incoming.fileno())
                    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink!=1
                            or metadata.st_size!=entry['bytes']): raise ValueError('Source type/size changed')
                    digest=hashlib.sha256();remaining=entry['bytes']
                    while remaining:
                        data=incoming.read(min(65536,remaining))
                        if not data: raise ValueError('Truncated source')
                        outgoing.write(data);digest.update(data);remaining-=len(data)
                    if incoming.read(1) or digest.hexdigest()!=entry['sha256']: raise ValueError('Source content changed')
                    os.fchmod(outgoing.fileno(),entry['mode']);outgoing.flush();os.fsync(outgoing.fileno())
        (destination/'manifest.json').write_bytes(raw);(destination/'manifest.json').chmod(0o644)
        for path in [destination,*destination.rglob('*')]:
            if path.is_dir():path.chmod(0o755)
        native_bundle.verify(destination)
        if source_names(source_fd)!=names|{'manifest.json'}:raise ValueError('Source tree changed while copying')
        with (destination/'manifest.json').open('rb') as stream:os.fsync(stream.fileno())
        for path in sorted([destination,*[p for p in destination.rglob('*') if p.is_dir()]],key=lambda p:len(p.parts),reverse=True):sync_dir(path)
        return manifest


class Store:
    def __init__(self, base=Path('/opt/farpane'), units=Path('/etc/systemd/system')):
        self.base=Path(base);self.units=Path(units)
        self.journal=self.base/'.native-transaction.json'
        self.state=self.base/'.native-state.json'

    def initialize(self):
        if os.geteuid()!=0:raise PermissionError('Native system installation requires root')
        secure_path(self.base,directory=True);secure_path(self.units,directory=True)
        if self.base.exists():
            secure_path(self.base/'.managed')
            if regular_bytes(self.base/'.managed',128).decode()!=MARKER:raise ValueError('Unmanaged installation')
        else:
            self.base.mkdir(mode=0o755);atomic_file(self.base/'.managed',MARKER.encode())
        for name,mode in (('releases',0o755),('.staged',0o700)):
            path=self.base/name;secure_path(path,directory=True)
            if path.exists() and stat.S_IMODE(path.stat().st_mode)!=mode:raise ValueError('Unexpected storage mode')
            path.mkdir(mode=mode,exist_ok=True)
        sync_dir(self.base)

    @contextmanager
    def locked(self, *, read_only=False):
        if read_only:
            if os.geteuid()!=0:raise PermissionError('System installation inspection requires root')
            secure_path(self.base,directory=True);secure_path(self.units,directory=True)
            secure_path(self.base/'.managed')
            if regular_bytes(self.base/'.managed',128).decode()!=MARKER:raise ValueError('Unmanaged installation')
        else:self.initialize()
        path=self.base/'.native-install.lock'
        secure_path(path)
        flags=os.O_RDONLY if read_only else os.O_CREAT|os.O_RDWR
        fd=os.open(path,flags|os.O_CLOEXEC|os.O_NOFOLLOW,0o600)
        try:
            meta=os.fstat(fd)
            if not stat.S_ISREG(meta.st_mode) or meta.st_uid!=0 or meta.st_nlink!=1 or meta.st_mode&0o077:
                raise ValueError('Untrusted installer lock')
            fcntl.flock(fd,(fcntl.LOCK_SH if read_only else fcntl.LOCK_EX)|fcntl.LOCK_NB);yield
        finally:os.close(fd)

    def current(self):
        path=self.base/'current'
        if not path.exists() and not path.is_symlink():return None
        if not path.is_symlink() or path.lstat().st_uid!=0:raise ValueError('Unmanaged current path')
        target=path.readlink()
        if len(target.parts)!=2 or target.parts[0]!='releases' or not ID.fullmatch(target.parts[1]):
            raise ValueError('Unmanaged current release link')
        if not (self.base/target).is_dir() or (self.base/target).is_symlink():raise ValueError('Invalid current release')
        return target.parts[1]

    def no_pending(self):
        if self.journal.exists() or self.journal.is_symlink():raise ValueError('An installation transaction requires recovery')

    def stage(self, source):
        with self.locked():
            self.no_pending()
            with tempfile.TemporaryDirectory(prefix='.copy-',dir=self.base/'.staged') as temporary:
                copied=Path(temporary)/'bundle';manifest=copy_bundle(Path(source),copied)
                name=manifest['artifact_id']
                if not ID.fullmatch(name):raise ValueError('Invalid native release ID')
                installed=self.base/'releases'/name
                destination=self.base/'.staged'/name
                if installed.exists() or installed.is_symlink():
                    if self.verify_release(name)!=manifest:raise ValueError('Installed release differs')
                    return {'artifact_id':name,'staged':False,'already_present':True,'active':self.current()==name}
                if destination.exists() or destination.is_symlink():
                    if native_bundle.verify(destination)!=manifest:raise ValueError('Staged release differs')
                else:
                    copied.rename(destination);sync_dir(destination.parent)
                return {'artifact_id':name,'staged':True,'active':False,'current':self.current()}

    def write_journal(self, value):
        atomic_file(self.journal,(json.dumps(value,indent=2)+'\n').encode(),0o600)

    def read_journal(self):
        secure_path(self.journal)
        record=json.loads(regular_bytes(self.journal))
        required={'schema','phase','old','target','old_unit','old_state','service','old_kind','target_kind','start_requested'}
        if (not isinstance(record,dict) or set(record)!=required
                or record.get('schema')!=1 or record.get('phase') not in ('prepared','fenced','switched','starting','committed','restored')
                or not isinstance(record.get('target'),str) or not ID.fullmatch(record['target'])
                or (record.get('old') is not None and (not isinstance(record['old'],str) or not ID.fullmatch(record['old'])))):
            raise ValueError('Invalid installation recovery record')
        service=record['service']
        if (not isinstance(service,dict) or set(service)!={'active','loaded','enabled'}
                or any(type(v) is not bool for v in service.values())
                or (not service['loaded'] and (service['active'] or service['enabled']))
                or type(record['start_requested']) is not bool or record['old']==record['target']
                or record['target_kind'] not in ('legacy','farpane-native')
                or record['old_kind'] not in (None,'legacy','farpane-native')
                or (record['old'] is None)!=(record['old_unit'] is None)
                or (record['old'] is None)!=(record['old_kind'] is None)):
            raise ValueError('Invalid recovery service/identity state')
        for key in ('old_unit','old_state'):
            if record.get(key) is not None:
                if not isinstance(record[key],str) or len(base64.b64decode(record[key],validate=True))>65536:
                    raise ValueError('Invalid previous installation metadata')
        return record

    def verify_release(self, name, legacy_verify=None):
        if not isinstance(name,str) or not ID.fullmatch(name):raise ValueError('Invalid release ID')
        path=self.base/'releases'/name;secure_path(path,directory=True)
        for item in path.rglob('*'):
            meta=item.lstat()
            if meta.st_uid!=0 or (not item.is_symlink() and meta.st_mode&0o022):raise ValueError('Untrusted release contents')
            if not any(check(meta.st_mode) for check in (stat.S_ISREG,stat.S_ISDIR,stat.S_ISLNK)):
                raise ValueError('Unexpected special object in release')
        manifest=json.loads(regular_bytes(path/'manifest.json'))
        if manifest.get('artifact_id')!=name:raise ValueError('Release name mismatch')
        if manifest.get('kind')=='farpane-native':return native_bundle.verify(path,allow_private=True)
        if legacy_verify is None:raise ValueError('Legacy verifier required')
        manifest=legacy_verify(path)
        if 'linux-gpu-media' not in manifest['features'] or not name.startswith('farpane-p1-'):
            raise ValueError('The CPU-only B0 release is not a supported rollback target')
        return manifest

    def expected_unit(self, name, manifest):
        if manifest.get('kind')=='farpane-native':
            template=regular_bytes(self.base/'releases'/name/'systemd/farpane.service').decode()
            if template.count('@FARPANE_RELEASE@')!=2:raise ValueError('Unexpected native service template')
            return template.replace('@FARPANE_RELEASE@',str(self.base/'releases'/name)).encode()
        # Exact legacy unit, not a broad marker-only overwrite rule.
        return ('# X-FarPane-Managed=true\n[Unit]\nDescription=FarPane Linux host\nAfter=network.target\n\n'
                '[Service]\nType=simple\nExecStart='+str(self.base/'farpane')+' --service\n'
                'WorkingDirectory='+str(self.base)+'\nRestart=on-failure\nRestartSec=3\nTimeoutStopSec=20\nKillMode=mixed\n\n'
                '[Install]\nWantedBy=multi-user.target\n').encode()

    def validate_links(self):
        for name,target in [('farpane','current/farpane'),('lib','current/lib')]:
            path=self.base/name
            if path.exists() or path.is_symlink():
                if not path.is_symlink() or path.lstat().st_uid!=0 or str(path.readlink())!=target:
                    raise ValueError('Unmanaged product entrypoint: '+name)

    def begin(self, target, *, expected_current, service_snapshot, legacy_verify=None, start=False):
        """Caller holds lock and has checked maintenance authorization/runtime."""
        self.no_pending();self.validate_links();old=self.current()
        if old!=expected_current:raise ValueError('Current release changed since planning')
        if old==target:raise ValueError('Target is already current')
        previous_manifest=self.verify_release(old,legacy_verify) if old else None
        unit=self.units/'farpane.service';secure_path(unit)
        old_unit=regular_bytes(unit,65536) if unit.exists() else None
        if old and old_unit!=self.expected_unit(old,previous_manifest):raise ValueError('Unmanaged or modified service unit')
        if not old and old_unit is not None:raise ValueError('An existing unit has no managed current release')
        secure_path(self.state)
        old_state=regular_bytes(self.state,65536) if self.state.exists() else None
        staged=self.base/'.staged'/target;destination=self.base/'releases'/target
        if not ID.fullmatch(target):raise ValueError('Invalid target release')
        if destination.exists():manifest=self.verify_release(target,legacy_verify)
        else:manifest=native_bundle.verify(staged)
        record={'schema':1,'phase':'prepared','old':old,'target':target,
                'old_unit':base64.b64encode(old_unit).decode() if old_unit is not None else None,
                'old_state':base64.b64encode(old_state).decode() if old_state is not None else None,
                'service':service_snapshot,'old_kind':previous_manifest.get('kind','legacy') if old else None,
                'target_kind':manifest.get('kind','legacy'),'start_requested':bool(start)}
        self.write_journal(record)
        # Permission fences prevent ordinary launchers/autostart from executing
        # either generation while root/user processes are being coordinated.
        if old:self.fence(old)
        if not destination.exists():
            staged.chmod(0o700);sync_dir(staged)
            staged.rename(destination);sync_dir(staged.parent);sync_dir(destination.parent)
        else:self.fence(target)
        record['phase']='fenced';self.write_journal(record)
        return record

    def fence(self, name):
        path=self.base/'releases'/name
        secure_path(path,directory=True);path.chmod(0o700);sync_dir(path)

    def check_recovery_files(self, record, legacy_verify=None):
        """Never overwrite a separate administrator's change during recovery."""
        self.validate_links()
        if self.current() not in (record['old'],record['target']):
            raise ValueError('Another release replaced the transaction')
        candidates=[base64.b64decode(record['old_unit'],validate=True) if record['old_unit'] else None]
        if (self.base/'releases'/record['target']).exists():
            target=self.verify_release(record['target'],legacy_verify)
            candidates.append(self.expected_unit(record['target'],target))
        unit=self.units/'farpane.service';secure_path(unit)
        actual=regular_bytes(unit,65536) if unit.exists() else None
        if actual not in candidates:raise ValueError('Service unit changed outside this transaction')
        secure_path(self.state)
        actual_state=regular_bytes(self.state,65536) if self.state.exists() else None
        previous_state=base64.b64decode(record['old_state'],validate=True) if record['old_state'] else None
        committed_state=(json.dumps(self.new_state(record),indent=2)+'\n').encode()
        if actual_state not in (previous_state,committed_state):
            raise ValueError('Installation receipt changed outside this transaction')

    def switch_files(self, record, *, quiescent, legacy_verify=None):
        if quiescent is not True:raise ValueError('Runtime quiescence has not been verified')
        if self.current()!=record['old']:raise ValueError('Current changed during transaction')
        target=record['target'];manifest=self.verify_release(target,legacy_verify)
        atomic_file(self.units/'farpane.service',self.expected_unit(target,manifest))
        link(self.base/'current','releases/'+target)
        link(self.base/'farpane','current/farpane');link(self.base/'lib','current/lib')
        record['phase']='switched';self.write_journal(record)

    def expose(self, record):
        if self.current()!=record['target']:raise ValueError('Target is not selected')
        path=self.base/'releases'/record['target'];path.chmod(0o755);sync_dir(path)
        record['phase']='starting';self.write_journal(record)

    def new_state(self, record):
        return {'schema':1,'active':record['target'],'previous':record['old'],
               'user_integration_required':True,'runtime_ready':False}

    def commit(self, record, *, healthy):
        if healthy is not True:raise ValueError('Runtime startup has not been verified')
        if record['phase']!='starting' or self.current()!=record['target']:
            raise ValueError('Release changed before commit')
        state=self.new_state(record)
        atomic_file(self.state,(json.dumps(state,indent=2)+'\n').encode())
        record['phase']='committed';self.write_journal(record)
        self.journal.unlink();sync_dir(self.base)
        return state

    def restore_files(self, record, *, quiescent):
        if quiescent is not True:raise ValueError('Target runtime must stop before recovery')
        old=record['old'];target=record['target']
        if self.current() not in (old,target):raise ValueError('Another release replaced the transaction')
        target_path=self.base/'releases'/target
        if target_path.exists():self.fence(target)
        staged=self.base/'.staged'/target
        if staged.exists():staged.chmod(0o755);sync_dir(staged)
        unit=self.units/'farpane.service'
        if record['old_unit'] is None:unit.unlink(missing_ok=True);sync_dir(self.units)
        else:atomic_file(unit,base64.b64decode(record['old_unit'],validate=True))
        if old:
            link(self.base/'current','releases/'+old)
            previous=self.base/'releases'/old;previous.chmod(0o755);sync_dir(previous)
        else:
            for name in ('current','farpane','lib'):(self.base/name).unlink(missing_ok=True)
        sync_dir(self.base);sync_dir(self.base/'releases')
        if record['old_state'] is None:self.state.unlink(missing_ok=True);sync_dir(self.base)
        else:atomic_file(self.state,base64.b64decode(record['old_state'],validate=True))
        record['phase']='restored';self.write_journal(record)

    def finish_restore(self, record, *, healthy):
        if healthy is not True:raise ValueError('Previous runtime recovery has not been verified')
        if record['phase']!='restored' or self.current()!=record['old']:
            raise ValueError('Release changed during recovery')
        self.journal.unlink();sync_dir(self.base)
