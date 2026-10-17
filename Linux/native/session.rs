//! Native root -> desktop launch, without sudo or inherited root settings.
use hbb_common::{
    anyhow::anyhow,
    bail, libc,
    users::{self, os::unix::UserExt},
    ResultType,
};
use std::{
    ffi::{CString, OsStr},
    fs,
    os::unix::{
        ffi::OsStrExt,
        fs::{FileTypeExt, MetadataExt},
        process::CommandExt,
    },
    path::PathBuf,
    process::{Child, Command},
};

fn groups(name: &OsStr, primary: libc::gid_t) -> ResultType<Vec<libc::gid_t>> {
    let name = CString::new(name.as_bytes())?;
    let mut count = 32;
    let mut groups = vec![0; count as usize];
    let mut result =
        unsafe { libc::getgrouplist(name.as_ptr(), primary, groups.as_mut_ptr(), &mut count) };
    if result < 0 {
        if !(1..=4096).contains(&count) {
            bail!("Desktop group list exceeds limit");
        }
        groups.resize(count as usize, 0);
        result =
            unsafe { libc::getgrouplist(name.as_ptr(), primary, groups.as_mut_ptr(), &mut count) };
    }
    if result < 0 || count < 1 || count as usize > groups.len() {
        bail!("Cannot resolve desktop supplementary groups");
    }
    // Only the count returned by NSS belongs to the user; unused zero-filled
    // capacity must never accidentally become supplementary group root.
    groups.truncate(count as usize);
    groups.sort_unstable();
    groups.dedup();
    Ok(groups)
}

fn command(
    uid: &str,
    username: &str,
    display: &str,
    xauth: &str,
    wayland: &str,
    dbus: &str,
    protocol: &str,
) -> ResultType<Command> {
    if unsafe { libc::geteuid() } != 0 {
        bail!("Desktop Host launch requires the root service");
    }
    let uid = uid.parse::<u32>()?;
    if uid == 0 {
        bail!("Native Host cannot run as root");
    }
    let user =
        users::get_user_by_uid(uid).ok_or_else(|| anyhow!("Desktop account no longer exists"))?;
    if user.name() != OsStr::new(username) {
        bail!("Desktop UID/account mismatch");
    }
    let runtime = PathBuf::from(format!("/run/user/{uid}"));
    let metadata = fs::symlink_metadata(&runtime)?;
    if !metadata.is_dir() || metadata.uid() != uid || metadata.mode() & 0o077 != 0 {
        bail!("Desktop runtime directory is not private to its user");
    }
    let gid = user.primary_group_id();
    let groups = groups(user.name(), gid)?;
    let parent = unsafe { libc::getpid() };
    let executable = fs::canonicalize(std::env::current_exe()?)?;
    let mut child = Command::new(executable);
    child
        .arg("--server")
        .env_clear()
        .current_dir(user.home_dir())
        .env("PATH", "/usr/local/bin:/usr/bin:/bin")
        .env("HOME", user.home_dir())
        .env("USER", user.name())
        .env("LOGNAME", user.name())
        .env("LANG", "C.UTF-8")
        .env("TERM", "xterm-256color")
        .env("XDG_RUNTIME_DIR", &runtime);
    for (key, value) in [
        ("DISPLAY", display),
        ("XAUTHORITY", xauth),
        ("WAYLAND_DISPLAY", wayland),
    ] {
        if !value.is_empty() {
            child.env(key, value);
        }
    }
    if matches!(protocol, "x11" | "wayland") {
        child.env("XDG_SESSION_TYPE", protocol);
    }
    if !dbus.is_empty() {
        child.env("DBUS_SESSION_BUS_ADDRESS", dbus);
    } else {
        // X11 discovery does not return a bus address. Modern user sessions
        // expose the per-user bus here; don't inherit the root service's bus.
        let bus = runtime.join("bus");
        if fs::symlink_metadata(&bus).is_ok_and(|m| m.file_type().is_socket() && m.uid() == uid) {
            child.env(
                "DBUS_SESSION_BUS_ADDRESS",
                format!("unix:path={}", bus.display()),
            );
        }
    }
    unsafe {
        child.pre_exec(move || {
            // The root loop installed a SIGTERM handler. Reset it before the
            // parent-death signal so a death between fork and exec cannot be
            // consumed by the inherited handler and leave an orphan Host.
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = libc::SIG_DFL;
            let mut unblocked: libc::sigset_t = std::mem::zeroed();
            libc::sigemptyset(&mut action.sa_mask);
            libc::sigemptyset(&mut unblocked);
            libc::sigaddset(&mut unblocked, libc::SIGTERM);
            if libc::sigaction(libc::SIGTERM, &action, std::ptr::null_mut()) != 0
                || libc::sigprocmask(libc::SIG_UNBLOCK, &unblocked, std::ptr::null_mut()) != 0
            {
                return Err(std::io::Error::last_os_error());
            }
            if libc::setgroups(groups.len(), groups.as_ptr()) != 0
                || libc::setresgid(gid, gid, gid) != 0
                || libc::setresuid(uid, uid, uid) != 0
                || libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0
                || libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM, 0, 0, 0) != 0
            {
                return Err(std::io::Error::last_os_error());
            }
            if libc::getppid() != parent {
                return Err(std::io::Error::from_raw_os_error(libc::ESRCH));
            }
            Ok(())
        });
    }
    Ok(child)
}

pub fn spawn(
    uid: &str,
    username: &str,
    display: &str,
    xauth: &str,
    wayland: &str,
    dbus: &str,
    protocol: &str,
) -> ResultType<Child> {
    Ok(command(uid, username, display, xauth, wayland, dbus, protocol)?.spawn()?)
}

pub fn spawn_desktop(
    session: &super::discovery::Session,
    env: &super::discovery::Environment,
) -> ResultType<Child> {
    let value = |key: &str| env.get(key).map(String::as_str).unwrap_or("");
    let mut child = command(
        &session.key.uid.to_string(),
        &session.username,
        value("DISPLAY"),
        value("XAUTHORITY"),
        value("WAYLAND_DISPLAY"),
        value("DBUS_SESSION_BUS_ADDRESS"),
        super::discovery::protocol(session),
    )?;
    child.envs(env);
    Ok(child.spawn()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn supplementary_groups_use_only_the_nss_count() {
        let uid = unsafe { libc::getuid() };
        let user = users::get_user_by_uid(uid).unwrap();
        let actual = groups(user.name(), user.primary_group_id()).unwrap();
        assert!(actual.contains(&user.primary_group_id()));
        let expected = Command::new("id")
            .args(["-G", user.name().to_str().unwrap()])
            .output()
            .unwrap();
        assert!(expected.status.success());
        let mut expected = String::from_utf8(expected.stdout)
            .unwrap()
            .split_whitespace()
            .map(|v| v.parse::<u32>().unwrap())
            .collect::<Vec<_>>();
        expected.sort_unstable();
        expected.dedup();
        assert_eq!(actual, expected);
    }
}
