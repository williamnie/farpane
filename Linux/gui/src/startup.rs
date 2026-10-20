//! 只管理系统已安装的 FarPane 服务，不启动/停止当前服务，也不修改其他单元。
use std::{
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

const QUERY: &[&str] = &[
    "--system",
    "--no-pager",
    "show",
    "--property=LoadState",
    "--property=UnitFileState",
    "farpane.service",
];
const ENABLE: &[&str] = &["--system", "--no-pager", "enable", "farpane.service"];
const DISABLE: &[&str] = &["--system", "--no-pager", "disable", "farpane.service"];

fn run(arguments: &[&str]) -> Result<String, String> {
    // 不经过 shell，不传入用户输入；systemd 通过桌面的 polkit 授权代理请求管理员授权。
    let mut child = Command::new("/usr/bin/systemctl")
        .args(arguments)
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "无法访问系统服务管理器。".to_string())?;
    let timeout = if arguments == QUERY { 5 } else { 90 };
    let deadline = Instant::now() + Duration::from_secs(timeout);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(50)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("系统服务操作超时或无法完成，请重试。".into());
            }
        }
    }
    let output = child
        .wait_with_output()
        .map_err(|_| "无法读取系统服务状态。".to_string())?;
    if !output.status.success() {
        return Err(if arguments == QUERY {
            "无法读取开机自启状态，请确认已安装 FarPane 系统服务。"
        } else {
            "更改失败或管理员授权已取消；请确认桌面支持系统授权后重试。"
        }
        .into());
    }
    String::from_utf8(output.stdout).map_err(|_| "系统返回了无法识别的服务状态。".into())
}

fn parse_status(output: &str) -> Result<bool, String> {
    let mut loaded = None;
    let mut enabled = None;
    for line in output.lines() {
        if let Some(value) = line.strip_prefix("LoadState=") {
            if loaded.replace(value).is_some() {
                return Err("系统返回了不一致的服务状态。".into());
            }
        } else if let Some(value) = line.strip_prefix("UnitFileState=") {
            if enabled.replace(value).is_some() {
                return Err("系统返回了不一致的服务状态。".into());
            }
        }
    }
    if loaded != Some("loaded") {
        return Err("FarPane 系统服务未安装或已被系统屏蔽，无法设置开机自启。".into());
    }
    match enabled {
        Some("enabled") => Ok(true),
        Some("disabled") => Ok(false),
        _ => Err("服务由其他系统策略管理，无法在此更改开机自启。".into()),
    }
}

pub fn observe() -> Result<bool, String> {
    parse_status(&run(QUERY)?)
}

pub fn set_enabled(enabled: bool) -> Result<bool, String> {
    change_with(enabled, run)
}

fn change_with(
    enabled: bool,
    mut command: impl FnMut(&[&str]) -> Result<String, String>,
) -> Result<bool, String> {
    let before = parse_status(&command(QUERY)?)?;
    if before == enabled {
        return Ok(before);
    }
    command(if enabled { ENABLE } else { DISABLE })?;
    let after = parse_status(&command(QUERY)?)?;
    if after != enabled {
        return Err("系统尚未应用开机自启更改，请重试。".into());
    }
    Ok(after)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(enabled: bool) -> String {
        format!(
            "LoadState=loaded\nUnitFileState={}\n",
            if enabled { "enabled" } else { "disabled" }
        )
    }

    #[test]
    fn persistent_state_is_distinct_from_runtime_or_unsupported_state() {
        assert_eq!(parse_status(&status(true)), Ok(true));
        assert_eq!(parse_status(&status(false)), Ok(false));
        for state in ["enabled-runtime", "masked", "static", "alias", ""] {
            assert!(parse_status(&format!("LoadState=loaded\nUnitFileState={state}\n")).is_err());
        }
        assert!(parse_status("LoadState=not-found\nUnitFileState=disabled\n").is_err());
        assert!(parse_status("UnitFileState=enabled\n").is_err());
        assert!(
            parse_status("LoadState=loaded\nUnitFileState=enabled\nUnitFileState=disabled")
                .is_err()
        );
    }

    #[test]
    fn changing_startup_never_starts_or_stops_the_service() {
        for desired in [true, false] {
            let mut calls = Vec::new();
            let result = change_with(desired, |args| {
                calls.push(args.iter().map(|s| s.to_string()).collect::<Vec<_>>());
                Ok(match calls.len() {
                    1 => status(!desired),
                    2 => String::new(),
                    3 => status(desired),
                    _ => panic!("unexpected call"),
                })
            });
            assert_eq!(result, Ok(desired));
            assert_eq!(calls[0], QUERY);
            assert_eq!(calls[1], if desired { ENABLE } else { DISABLE });
            assert_eq!(calls[2], QUERY);
        }
    }

    #[test]
    fn already_applied_state_does_not_request_authorization() {
        let mut reads = 0;
        assert_eq!(
            change_with(true, |args| {
                assert_eq!(args, QUERY);
                reads += 1;
                Ok(status(true))
            }),
            Ok(true)
        );
        assert_eq!(reads, 1);
    }

    #[test]
    fn denial_does_not_claim_success_or_retry_mutation() {
        let mut calls = 0;
        let result = change_with(true, |_| {
            calls += 1;
            if calls == 1 {
                Ok(status(false))
            } else {
                Err("cancelled".into())
            }
        });
        assert_eq!(result, Err("cancelled".into()));
        assert_eq!(calls, 2);
    }

    #[test]
    fn ineffective_or_unsupported_changes_fail() {
        assert!(change_with(true, |_| Ok(status(false))).is_err());
        let mut calls = 0;
        assert!(change_with(true, |_| {
            calls += 1;
            Ok("LoadState=masked\nUnitFileState=masked\n".into())
        })
        .is_err());
        assert_eq!(calls, 1);
    }
}
