//! Exact process selection and stable-handle signalling. No process-name regex.
use hbb_common::{bail, libc, ResultType};
use std::{
    fs,
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd},
        unix::fs::MetadataExt,
    },
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

pub fn start_ticks(pid: u32) -> ResultType<u64> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat"))?;
    let tail = stat
        .rsplit_once(") ")
        .ok_or_else(|| hbb_common::anyhow::anyhow!("Invalid process stat"))?
        .1;
    Ok(tail
        .split_whitespace()
        .nth(19)
        .ok_or_else(|| hbb_common::anyhow::anyhow!("Missing process start time"))?
        .parse()?)
}
pub struct Process {
    fd: OwnedFd,
    pub pid: u32,
    pub start: u64,
    exe: PathBuf,
    uid: Option<u32>,
    role: String,
}
impl Process {
    pub fn exact(pid: u32, exe: &Path, uid: Option<u32>, role: &str) -> ResultType<Self> {
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) } as i32;
        if fd < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };
        let mut process = Self {
            fd,
            pid,
            start: 0,
            exe: exe.to_owned(),
            uid,
            role: role.to_owned(),
        };
        if process.exited()? {
            return Err(std::io::Error::from_raw_os_error(libc::ESRCH).into());
        }
        let proc = std::path::PathBuf::from(format!("/proc/{pid}"));
        if fs::read_link(proc.join("exe"))? != exe {
            bail!("Executable mismatch");
        }
        if uid.is_some_and(|uid| fs::metadata(&proc).map(|m| m.uid() != uid).unwrap_or(true)) {
            bail!("UID mismatch");
        }
        let command = fs::read(proc.join("cmdline"))?;
        if command.split(|c| *c == 0).nth(1) != Some(role.as_bytes()) {
            bail!("Role mismatch");
        }
        if matches!(role, "--server" | "--service" | "--check-hwcodec-config")
            && command.split(|c| *c == 0).filter(|v| !v.is_empty()).count() != 2
        {
            bail!("Unexpected arguments for native role");
        }
        process.start = start_ticks(pid)?;
        if process.exited()? {
            return Err(std::io::Error::from_raw_os_error(libc::ESRCH).into());
        }
        Ok(process)
    }
    pub fn exited(&self) -> ResultType<bool> {
        let mut poll = libc::pollfd {
            fd: self.fd.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let rc = unsafe { libc::poll(&mut poll, 1, 0) };
        if rc < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(rc != 0)
    }
    fn signal(&self, signal: i32) -> ResultType<()> {
        if self.exited()? {
            return Ok(());
        }
        let current = Self::exact(self.pid, &self.exe, self.uid, &self.role)?;
        if current.start != self.start {
            bail!("Process identity changed before signalling");
        }
        if unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                self.fd.as_raw_fd(),
                signal,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            )
        } < 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(())
    }
    pub fn stop(&self) -> ResultType<()> {
        if self.exited()? {
            return Ok(());
        }
        self.signal(libc::SIGTERM)?;
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if self.exited()? {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        self.signal(libc::SIGKILL)?;
        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline {
            if self.exited()? {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        bail!("Process has not exited after SIGKILL; refusing an overlapping replacement")
    }
}
pub fn servers(uid: Option<u32>) -> ResultType<Vec<Process>> {
    let exe = fs::canonicalize(std::env::current_exe()?)?;
    let mut result = Vec::new();
    for entry in fs::read_dir("/proc")? {
        let entry = entry?;
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|s| s.parse::<u32>().ok())
        else {
            continue;
        };
        let inspect = || -> ResultType<Option<Process>> {
            if uid.is_some_and(|uid| {
                fs::metadata(entry.path())
                    .map(|m| m.uid() != uid)
                    .unwrap_or(false)
            }) {
                return Ok(None);
            }
            if fs::read_link(entry.path().join("exe"))? != exe {
                return Ok(None);
            }
            let command = fs::read(entry.path().join("cmdline"))?;
            if command.split(|c| *c == 0).nth(1) != Some(b"--server") {
                return Ok(None);
            }
            Ok(Some(Process::exact(pid, &exe, uid, "--server")?))
        };
        match inspect() {
            Ok(Some(process)) => result.push(process),
            Ok(None) => {}
            Err(error)
                if error.downcast_ref::<std::io::Error>().is_some_and(|e| {
                    e.kind() == std::io::ErrorKind::NotFound
                        || e.raw_os_error() == Some(libc::ESRCH)
                }) => {}
            Err(error) => return Err(error),
        }
    }
    Ok(result)
}
pub fn stop_servers(uid: Option<u32>) -> ResultType<()> {
    for process in servers(uid)? {
        process.stop()?;
    }
    if !servers(uid)?.is_empty() {
        bail!("Native Host appeared during shutdown; replacement refused");
    }
    Ok(())
}

pub fn stop_other_servers(active_uid: u32) -> ResultType<()> {
    for process in servers(None)? {
        if fs::metadata(format!("/proc/{}", process.pid))?.uid() != active_uid {
            process.stop()?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn process_identity_rejects_other_roles_uids_and_paths() {
        let pid = std::process::id();
        let exe = fs::canonicalize(std::env::current_exe().unwrap()).unwrap();
        let role = std::env::args().nth(1).unwrap();
        let own = Process::exact(pid, &exe, Some(unsafe { libc::geteuid() }), &role).unwrap();
        assert!(!own.exited().unwrap());
        assert_eq!(own.start, start_ticks(pid).unwrap());
        assert!(Process::exact(pid, &exe, Some(u32::MAX), &role).is_err());
        assert!(Process::exact(pid, &exe, None, "--server").is_err());
        assert!(Process::exact(pid, Path::new("/not/farpane-core"), None, &role).is_err());
    }
}
