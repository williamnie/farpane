"""Unprivileged, journaled desktop integration; never starts applications."""
import base64
from contextlib import contextmanager
import errno
import fcntl
import grp
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import tempfile
import uuid

from native_install import ID, regular_bytes, secure_path, sync_dir

LIMIT=4*1024*1024
FILES={
    'desktop':'share/applications/org.farpane.FarPane.desktop',
    'dbus':'share/dbus-1/services/org.farpane.FarPane.service',
    'svg':'share/icons/hicolor/scalable/apps/org.farpane.FarPane.svg',
    'png':'share/icons/hicolor/1024x1024/apps/org.farpane.FarPane.png',
}


def encoded(data):return None if data is None else base64.b64encode(data).decode()
def decoded(data):
    if data is None:return None
    if not isinstance(data,str) or len(data)>LIMIT*2:raise ValueError('Invalid desktop backup')
    result=base64.b64decode(data,validate=True)
    if len(result)>LIMIT:raise ValueError('Desktop backup exceeds limit')
    return result


def private_user_group(uid, gid):
    """A user-private primary group grants no other account write access."""
    try:
        account=pwd.getpwuid(uid);group=grp.getgrgid(gid)
        return (account.pw_gid==gid and group.gr_name==account.pw_name
                and set(group.gr_mem)<={account.pw_name}
                and not any(p.pw_uid!=uid and p.pw_gid==gid for p in pwd.getpwall()))
    except (KeyError,OSError):
        return False


def no_extended_acl(path):
    # A named ACL entry can grant another account write access even when the
    # owning group is private. Do not admit that layout via the group exception.
    for name in ('system.posix_acl_access','system.posix_acl_default'):
        try:os.getxattr(path,name,follow_symlinks=False)
        except OSError as error:
            if error.errno in (errno.ENODATA,errno.ENOTSUP):continue
            return False
        else:return False
    return True


class UserIntegration:
    def __init__(self,store,home,*,data=None,config=None,state=None):
        self.uid=os.geteuid()
        if self.uid==0:raise PermissionError('Run desktop integration as the desktop user')
        primary=pwd.getpwuid(self.uid).pw_gid
        self.private_gid=primary if private_user_group(self.uid,primary) else None
        self.store=store;self.home=Path(home)
        self.data=Path(data) if data else self.home/'.local/share'
        self.config=Path(config) if config else self.home/'.config'
        self.state=(Path(state) if state else self.home/'.local/state')/'farpane/install'
        self.paths={key:self.data/relative.removeprefix('share/') for key,relative in FILES.items()}
        for name in ('farpane','FarPane','org.farpane.FarPane'):
            self.paths['autostart-'+name]=self.config/'autostart'/(name+'.desktop')
        self.paths['receipt']=self.state/'installed.json'
        self.pending=self.state/'pending.json'

    def check(self,path,*,directory=False,create=False):
        path=Path(path)
        if not path.is_absolute() or '..' in path.parts:raise ValueError('Expected absolute user integration path')
        for ancestor in reversed([path,*path.parents]):
            if not ancestor.exists() and not ancestor.is_symlink():
                if ancestor==path and not directory:return
                if not create:continue
                ancestor.mkdir(mode=0o700 if ancestor==self.state else 0o755)
            metadata=ancestor.lstat() if ancestor.exists() or ancestor.is_symlink() else None
            if metadata is None:continue
            is_directory=ancestor!=path or directory
            writable_by_others=(metadata.st_mode&0o002 or
                (metadata.st_mode&0o020 and not
                 (metadata.st_uid==self.uid and metadata.st_gid==self.private_gid
                  and no_extended_acl(ancestor))))
            if (metadata.st_uid not in (0,self.uid) or writable_by_others
                    or (is_directory and not stat.S_ISDIR(metadata.st_mode))
                    or (not is_directory and (not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink!=1))):
                raise ValueError('Untrusted user integration path: '+str(ancestor))
            if ancestor==path and metadata.st_uid!=self.uid:
                raise ValueError('Desktop entry/state must belong to this user')

    def read(self,path):
        self.check(path)
        return regular_bytes(path,LIMIT) if path.exists() else None

    def write(self,path,data,mode=0o644):
        self.check(path,create=True)
        if data is None:
            path.unlink(missing_ok=True)
            if path.parent.exists():sync_dir(path.parent)
            return
        fd,temporary=tempfile.mkstemp(prefix='.farpane-',dir=path.parent)
        try:
            with os.fdopen(fd,'wb') as stream:
                os.fchmod(stream.fileno(),mode);stream.write(data);stream.flush();os.fsync(stream.fileno())
            os.replace(temporary,path);sync_dir(path.parent)
        finally:Path(temporary).unlink(missing_ok=True)

    @contextmanager
    def locked(self):
        self.check(self.home,directory=True)
        self.check(self.state,directory=True,create=True)
        if stat.S_IMODE(self.state.stat().st_mode)!=0o700:raise ValueError('Desktop installation state must be private')
        path=self.state/'lock';self.check(path)
        fd=os.open(path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
        try:
            if os.fstat(fd).st_nlink!=1:raise ValueError('Invalid desktop integration lock')
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);yield
        finally:os.close(fd)

    def selected(self,target):
        secure_path(self.store.base,directory=True)
        if self.store.journal.exists() or self.store.journal.is_symlink():
            raise ValueError('System installation recovery must finish first')
        if self.store.current()!=target:raise ValueError('System release differs from desktop transaction')

    def secure_configuration(self):
        # Legacy desktop umask 0002 can leave this product's directory 0775.
        # The native config owner rejects group-writable directories. Tighten
        # only FarPane's own directory after checking the entire user path;
        # never alter unrelated icon/config ancestors or configuration bytes.
        directory=self.config/'farpane'
        self.check(directory.parent,directory=True,create=True)
        try:directory.mkdir(mode=0o700)
        except FileExistsError:pass
        self.check(directory,directory=True)
        fd=os.open(directory,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC)
        try:
            meta=os.fstat(fd)
            if meta.st_uid!=self.uid or not stat.S_ISDIR(meta.st_mode):
                raise ValueError('Unexpected FarPane configuration directory')
            os.fchmod(fd,0o700);os.fsync(fd)
        finally:os.close(fd)

    def legacy_desktop(self):
        return ('[Desktop Entry]\nType=Application\nName=FarPane\nComment=FarPane Linux development build\n'
                'Exec="'+str(self.store.base/'farpane')+'"\nTerminal=false\nCategories=Network;RemoteAccess;\n'
                'StartupWMClass=Farpane\nX-FarPane-Managed=true\n').encode()

    def managed_autostart(self,data,previous):
        if data is None:return True
        # The historical tray writer's exact FarPane-only content. It was
        # disabled in the pinned source, but older installations may retain it.
        if data==b'\n    [Desktop Entry]\n    Type=Application\n    Exec=farpane --tray\n    NoDisplay=false\n            ':return True
        # Explicitly managed entries are recognized only with a known command,
        # section and no extra actions/keys; a marker alone is insufficient.
        lines=data.decode('utf-8').splitlines()
        if len(lines)!=5 or lines[:3]!=['[Desktop Entry]','Type=Application','Name=FarPane'] or lines[-1]!='X-FarPane-Managed=true':return False
        commands={'Exec='+str(self.store.base/'farpane')+' --tray'}
        if previous:commands.add('Exec='+str(self.store.base/'releases'/previous/'farpane')+' --tray')
        return lines[3] in commands

    def receipt(self):
        raw=self.read(self.paths['receipt'])
        if raw is None:return None
        value=json.loads(raw)
        if (not isinstance(value,dict) or set(value)!={'schema','release','backup','hashes'} or value['schema']!=1
                or not isinstance(value['release'],str) or not ID.fullmatch(value['release'])
                or not isinstance(value['backup'],str) or not re.fullmatch('[0-9a-f]{32}',value['backup'])
                or not isinstance(value['hashes'],dict) or set(value['hashes'])!=set(FILES)):
            raise ValueError('Invalid desktop integration receipt')
        return value

    def journal(self,record):
        raw=(json.dumps(record,indent=2)+'\n').encode()
        if len(raw)>LIMIT:raise ValueError('Desktop transaction exceeds recovery limit')
        self.write(self.pending,raw,0o600)

    def record(self,path):
        raw=self.read(path)
        if raw is None:raise ValueError('No desktop transaction to recover')
        record=json.loads(raw)
        if (not isinstance(record,dict) or set(record)!={'schema','id','phase','target','previous','items'}
                or record['schema']!=1 or record['phase'] not in ('prepared','committed')
                or not isinstance(record['id'],str) or not re.fullmatch('[0-9a-f]{32}',record['id'])
                or not isinstance(record['items'],dict) or set(record['items'])!=set(self.paths)):
            raise ValueError('Invalid desktop transaction')
        for name in ('target','previous'):
            if record[name] is not None and (not isinstance(record[name],str) or not ID.fullmatch(record[name])):
                raise ValueError('Invalid desktop transaction release')
        for item in record['items'].values():
            if not isinstance(item,dict) or set(item)!={'old','new'}:raise ValueError('Invalid desktop transaction item')
            decoded(item['old']);decoded(item['new'])
        return record

    def compare(self,record):
        # Inspect every destination before any recovery write, preserving edits
        # made by the user after a crash or since the last successful install.
        for key,item in record['items'].items():
            if self.read(self.paths[key]) not in (decoded(item['old']),decoded(item['new'])):
                raise ValueError('Desktop entry changed outside transaction: '+key)

    def finish(self,record):
        self.write(self.state/'backups'/(record['id']+'.json'),(json.dumps(record,indent=2)+'\n').encode(),0o600)
        self.pending.unlink();sync_dir(self.state)

    def execute(self,record):
        self.journal(record)
        try:
            for key,item in record['items'].items():self.write(self.paths[key],decoded(item['new']),0o600 if key=='receipt' else 0o644)
            self.selected(record['target'])
            record['phase']='committed';self.journal(record);self.finish(record)
        except Exception:
            self.recover_locked();raise
        return {'release':record['target'],'desktop_installed':True,'processes_started':False,'backup':record['id']}

    def bind(self,target,previous):
        with self.locked():
            if self.pending.exists():raise ValueError('Desktop transaction requires recovery')
            self.selected(target)
            manifest=self.store.verify_release(target)
            if manifest.get('kind')!='farpane-native':raise ValueError('Expected native release')
            secure_path(self.store.state)
            system=json.loads(regular_bytes(self.store.state))
            if system.get('active')!=target or system.get('previous')!=previous:
                raise ValueError('System installation receipt differs from desktop request')
            receipt=self.receipt();old={key:self.read(path) for key,path in self.paths.items()}
            release=self.store.base/'releases'/target
            content={key:regular_bytes(release/relative,LIMIT) for key,relative in FILES.items()}
            for key in ('desktop','dbus'):
                if content[key].count(b'@FARPANE_RELEASE@')!=1:raise ValueError('Invalid desktop template')
                content[key]=content[key].replace(b'@FARPANE_RELEASE@',str(release).encode())
            for key in FILES:
                if old[key] is None:continue
                if receipt and hashlib.sha256(old[key]).hexdigest()==receipt['hashes'][key]:continue
                if key=='desktop' and old[key]==self.legacy_desktop():continue
                if old[key]==content[key]:continue
                raise ValueError('Refusing to overwrite an unmanaged desktop entry: '+key)
            for key in self.paths.keys()-FILES.keys()-{'receipt'}:
                if not self.managed_autostart(old[key],previous):raise ValueError('Unmanaged FarPane autostart entry: '+key)
                content[key]=None
            if receipt and receipt['release'] not in (target,previous):raise ValueError('Desktop receipt belongs to another release')
            hashes={key:hashlib.sha256(content[key]).hexdigest() for key in FILES}
            self.secure_configuration()
            if receipt and receipt['release']==target and receipt['hashes']==hashes and all(old[k]==content[k] for k in content):
                return {'release':target,'already_installed':True,'processes_started':False}
            identity=uuid.uuid4().hex
            content['receipt']=(json.dumps({'schema':1,'release':target,'backup':identity,'hashes':hashes},indent=2)+'\n').encode()
            record={'schema':1,'id':identity,'phase':'prepared','target':target,'previous':previous,
                    'items':{key:{'old':encoded(old[key]),'new':encoded(content[key])} for key in self.paths}}
            return self.execute(record)

    def refresh_desktop_cache(self):
        """Notify desktop consumers after a committed entry transaction.

        This derived, shared MIME cache is outside the rollback journal. A
        failed refresh leaves committed entries intact; repeating bind can
        retry it without creating another entry transaction or launching GUI.
        """
        directory=self.paths['desktop'].parent
        self.check(directory,directory=True)
        if not directory.is_dir():
            return {'status':'not-needed','helper_started':False}
        self.check(directory/'mimeinfo.cache')
        try:
            done=subprocess.run(['/usr/bin/update-desktop-database','--quiet',str(directory)],
                                stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL,timeout=10,check=False)
        except FileNotFoundError:
            return {'status':'unavailable','helper_started':False,
                    'error':'Install desktop-file-utils and repeat the user integration command'}
        except subprocess.TimeoutExpired:
            return {'status':'failed','helper_started':True,'error':'Desktop cache refresh timed out'}
        except OSError as error:
            return {'status':'failed','helper_started':False,'error':'Desktop cache helper could not start',
                    'errno':error.errno}
        return {'status':'refreshed' if done.returncode==0 else 'failed',
                'helper_started':True,'exit_code':done.returncode}

    def recover_locked(self):
        record=self.record(self.pending);self.compare(record)
        if record['phase']=='committed':
            self.finish(record);return {'recovered':'completed_desktop_commit'}
        for key,item in record['items'].items():self.write(self.paths[key],decoded(item['old']),0o600 if key=='receipt' else 0o644)
        self.pending.unlink();sync_dir(self.state)
        return {'recovered':'previous_desktop_entries','processes_started':False}

    def recover(self):
        with self.locked():return self.recover_locked()

    def rollback(self):
        with self.locked():
            if self.pending.exists():raise ValueError('Desktop transaction requires recovery')
            receipt=self.receipt()
            if receipt is None:raise ValueError('No managed desktop integration to restore')
            original=self.record(self.state/'backups'/(receipt['backup']+'.json'))
            if original['target']!=receipt['release']:raise ValueError('Desktop backup release mismatch')
            self.selected(original['previous']);self.compare(original)
            # Restores the prior receipt as bytes too, allowing a later rollback
            # through retained backups without recursively embedding history.
            record={'schema':1,'id':uuid.uuid4().hex,'phase':'prepared','target':original['previous'],'previous':original['target'],
                    'items':{key:{'old':encoded(self.read(self.paths[key])),'new':item['old']} for key,item in original['items'].items()}}
            return self.execute(record)
