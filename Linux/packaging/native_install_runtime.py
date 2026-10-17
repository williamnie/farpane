"""Maintenance coordinator: one product unit, exact executables and pidfds."""
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import time
from native_install import ID, sync_dir


class Process:
    def __init__(self,pid,allowed):
        self.fd=os.pidfd_open(pid);self.pid=pid
        try:
            if self.exited():raise ProcessLookupError(pid)
            proc=Path('/proc')/str(pid);self.exe=proc.joinpath('exe').readlink()
            if self.exe not in allowed:raise LookupError('Unrelated process')
            self.uid=proc.stat().st_uid
            args=proc.joinpath('cmdline').read_bytes().split(b'\0')
            self.args=[v for v in args[1:] if v]
            self.start=proc.joinpath('stat').read_text().rsplit(') ',1)[1].split()[19]
            self.role=self.classify(allowed[self.exe])
            if self.exited():raise ProcessLookupError(pid)
        except BaseException:
            os.close(self.fd);self.fd=-1;raise

    def classify(self,kind):
        first=self.args[0] if self.args else b''
        if first==b'--service' and len(self.args)==1 and self.uid==0 and kind!='gui':return 'service'
        if self.uid==0:raise ValueError('Unexpected root role for managed executable')
        if kind=='gui':
            if not self.args or self.args==[b'--gapplication-service']:return 'gui'
        elif kind=='native':
            if self.args==[b'--server']:return 'server'
            if len(self.args)==2 and first==b'--viewer' and self.args[1].isdigit():return 'viewer'
            if len(self.args)==1 and first in (b'--config-cli',b'--config-command',b'--version',b'--build-info',b'--check-hwcodec-config',b'--check-bundled-media'):return 'transient'
        else:
            if first in (b'--server',b'--cm',b'--cm-no-ui',b'--tray'):return first.decode()[2:]
            if not self.args or first in (b'--connect',b'--file-transfer',b'--noinstall'):return 'gui'
            if first in (b'--get-id',b'--version',b'--check-hwcodec-config'):return 'transient'
        raise ValueError('Unrecognized role for managed executable; refusing termination')

    def exited(self):
        poll=select.poll();poll.register(self.fd,select.POLLIN)
        return bool(poll.poll(0))

    def terminate(self):
        if not self.exited():
            if (Path('/proc')/str(self.pid)/'exe').readlink()!=self.exe:
                raise ValueError('Managed process changed executable before termination')
            signal.pidfd_send_signal(self.fd,signal.SIGTERM)

    def close(self):
        if self.fd>=0:os.close(self.fd);self.fd=-1


def scan(allowed):
    result=[]
    try:
        for proc in Path('/proc').iterdir():
            if not proc.name.isdecimal():continue
            try:
                # Avoid opening pidfds for unrelated system processes. The
                # matching process is then rechecked while held by a pidfd.
                executable=proc.joinpath('exe').readlink()
                if str(executable).endswith(' (deleted)') and Path(str(executable)[:-10]) in allowed:
                    raise ValueError('A managed running executable was deleted; refusing automatic switch')
                if executable not in allowed:
                    # A stale managed generation is not safe to overlap, even
                    # though this transaction is not authorized to stop it.
                    roots={path.parents[2] if kind=='native' else path.parents[1]
                           for path,kind in allowed.items()}
                    if any(executable.is_relative_to(root) for root in roots):
                        raise ValueError('Another managed release has a running executable')
                    continue
                result.append(Process(int(proc.name),allowed))
            except (FileNotFoundError,ProcessLookupError,LookupError):continue
        return result
    except BaseException:
        for process in result:process.close()
        raise


def stop_users(allowed,timeout=8):
    deadline=time.monotonic()+timeout
    while True:
        processes=scan(allowed)
        try:
            if not processes:return
            if any(p.role=='service' for p in processes):raise ValueError('Root service remains after stopping its unit')
            for process in processes:
                if process.role!='transient':process.terminate()
            if time.monotonic()>=deadline:
                raise TimeoutError('Managed processes have not exited; no SIGKILL or overlapping replacement')
        finally:
            for process in processes:process.close()
        time.sleep(.05)


class Systemd:
    def __init__(self,store):self.store=store;self.last_pid=0

    def command(self,*args):
        result=subprocess.run(['/usr/bin/systemctl','--system','--no-pager',*args],
                              capture_output=True,text=True,timeout=35)
        # Some systemctl releases report a nonzero status for an unloaded
        # unit. Accept only the explicit show response for this exact product;
        # transport errors and failed mutations remain failures.
        missing=(args[:2]==('show','farpane.service') and result.returncode in (1,4)
                 and 'LoadState=not-found' in result.stdout.splitlines())
        if result.returncode and not missing:result.check_returncode()
        return result.stdout

    def snapshot(self,allowed):
        output=self.command('show','farpane.service','-p','LoadState','-p','ActiveState','-p','MainPID',
                            '-p','FragmentPath','-p','DropInPaths','-p','ExecStart','-p','UnitFileState','-p','Names')
        values=dict(line.split('=',1) for line in output.splitlines() if '=' in line)
        if values.get('LoadState')=='not-found':
            if values.get('ActiveState') not in ('inactive','failed') or values.get('MainPID','0')!='0':
                raise ValueError('Unexpected missing service state')
            self.last_pid=0
            return {'active':False,'loaded':False,'enabled':False}
        if (values.get('LoadState')!='loaded' or values.get('FragmentPath')!=str(self.store.units/'farpane.service')
                or values.get('DropInPaths') or values.get('Names')!='farpane.service'
                or values.get('ActiveState') not in ('active','inactive','failed')
                or values.get('UnitFileState') not in ('enabled','disabled')):
            raise ValueError('Unmanaged, overridden or transitional FarPane unit')
        match=re.search(r'path=([^ ;]+) ; argv\[\]=([^;]+?) ;',values.get('ExecStart',''))
        if not match or match[2].strip()!=match[1]+' --service':raise ValueError('Unexpected service command')
        if Path(match[1]).resolve(strict=True) not in allowed:raise ValueError('Service executable is outside this transaction')
        pid=int(values.get('MainPID','0'))
        active=values['ActiveState']=='active'
        if active:
            if pid<=0:raise ValueError('Active service has no verified process')
            process=Process(pid,allowed)
            try:
                if process.role!='service':raise ValueError('MainPID is not the expected root role')
            finally:process.close()
        elif pid!=0:raise ValueError('Inactive unit still has a process')
        self.last_pid=pid
        return {'active':active,'loaded':True,'enabled':values['UnitFileState']=='enabled'}

    def stop(self,allowed):
        before=self.snapshot(allowed)
        if before['active']:self.command('stop','farpane.service')
        if self.snapshot(allowed)['active']:raise ValueError('Service did not stop')

    def reload(self):self.command('daemon-reload')

    def start(self):self.command('start','farpane.service')

    def healthy(self,allowed,wanted):
        # Stable process/role, not merely systemctl start's exit code. User
        # session/capture readiness remains a separate desktop acceptance gate.
        previous_pid=None
        for _ in range(3):
            if self.snapshot(allowed)['active']!=wanted:return False
            if previous_pid is not None and previous_pid!=self.last_pid:return False
            previous_pid=self.last_pid
            time.sleep(.2)
        return True


class Coordinator:
    def __init__(self,store,service,legacy_verify):
        self.store=store;self.service=service;self.legacy_verify=legacy_verify

    def allowed(self,*names,staged=False):
        result={}
        for name in set(n for n in names if n):
            if not isinstance(name,str) or not ID.fullmatch(name):raise ValueError('Invalid release ID')
            path=self.store.base/'releases'/name
            if path.exists():manifest=self.store.verify_release(name,self.legacy_verify)
            elif staged:
                import native_bundle
                manifest=native_bundle.verify(self.store.base/'.staged'/name,allow_private=True)
                if manifest['artifact_id']!=name:raise ValueError('Staged release name mismatch')
            else:raise ValueError('Missing managed release')
            if manifest.get('kind')=='farpane-native':
                result[path/'farpane']='gui';result[path/'libexec/farpane-core']='native'
            else:result[path/'farpane']='legacy'
        return result

    def preflight(self,target,expected_current):
        store=self.store;store.no_pending();old=store.current()
        if old!=expected_current:raise ValueError('Current release differs from requested plan')
        allowed=self.allowed(old,target,staged=True)
        snapshot=self.service.snapshot(allowed)
        processes=scan(allowed)
        try:
            roots=[p for p in processes if p.role=='service']
            if len(roots)!=(1 if snapshot['active'] else 0):raise ValueError('Service/process identity disagreement')
            summary=[{'pid':p.pid,'uid':p.uid,'role':p.role,'start_ticks':p.start} for p in processes]
        finally:
            for p in processes:p.close()
        return {'current':old,'target':target,'service':snapshot,'processes':summary,
                'configuration_touched':False,'maintenance_required':True}

    def apply(self,target,*,expected_current,maintenance=False,start=False):
        if maintenance is not True:raise ValueError('Switching requires an explicit maintenance window')
        store=self.store
        with store.locked():
            plan=self.preflight(target,expected_current)
            if target==expected_current:
                raise ValueError('Target is already current; no maintenance action needed')
            try:
                record=store.begin(target,expected_current=expected_current,service_snapshot=plan['service'],legacy_verify=self.legacy_verify,start=start)
                self.service.stop(self.allowed(record['old'],target))
                stop_users(self.allowed(record['old'],target))
                store.switch_files(record,quiescent=True,legacy_verify=self.legacy_verify)
                self.service.reload();store.expose(record)
                wanted=plan['service']['active'] or start
                if wanted:self.service.start()
                if not self.service.healthy(self.allowed(target),wanted):raise ValueError('New root service failed readiness')
                return store.commit(record,healthy=True)
            except Exception as error:
                if not store.journal.exists():raise
                try:self.recover_locked(store.read_journal())
                except Exception as recovery:
                    raise RuntimeError('Switch failed and recovery remains pending; inspect the transaction before retrying: '+str(recovery)) from error
                raise RuntimeError('Switch failed; previous release restored') from error

    def recover_locked(self,record):
        store=self.store;allowed=self.allowed(record['old'],record['target'],staged=True)
        store.check_recovery_files(record,self.legacy_verify)
        # A crash after durable commit but before deleting the journal must not
        # silently undo a successful installation.
        if record['phase']=='committed':
            wanted=record['service']['active'] or record.get('start_requested',False)
            if store.current()==record['target'] and self.service.healthy(self.allowed(record['target']),wanted):
                store.journal.unlink();sync_dir(store.base)
                return {'recovered':'completed_commit','active':record['target']}
        for name in (record['old'],record['target']):
            path=store.base/'releases'/name if name else None
            if path and path.exists():store.fence(name)
        self.service.stop(allowed);stop_users(allowed)
        store.restore_files(record,quiescent=True)
        self.service.reload()
        wanted=record['service']['active']
        if wanted:self.service.start()
        if not self.service.healthy(self.allowed(record['old']),wanted):raise ValueError('Previous service did not recover')
        store.finish_restore(record,healthy=True)
        return {'recovered':'previous_release','active':record['old']}

    def recover(self,*,maintenance=False):
        if maintenance is not True:raise ValueError('Recovery requires an explicit maintenance window')
        with self.store.locked():return self.recover_locked(self.store.read_journal())
