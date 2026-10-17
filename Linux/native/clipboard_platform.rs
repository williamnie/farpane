//! Explicit native desktop selection. Wayland never falls back to Xwayland.
use super::{clipboard_wayland as wl, clipboard_x11 as x11};
use bytes::Bytes;
use farpane_protocol::clipboard::{Part, Policy};
use hbb_common::{libc, ResultType};
use std::{os::fd::RawFd, time::Instant};

fn wayland() -> bool {
    std::env::var_os("WAYLAND_DISPLAY").is_some()
        || std::env::var_os("WAYLAND_SOCKET").is_some()
        || std::env::var("XDG_SESSION_TYPE").is_ok_and(|v| v.eq_ignore_ascii_case("wayland"))
}
pub fn ready() -> &'static str {
    if wayland() {
        "Wayland 剪贴板共享就绪"
    } else {
        "X11 剪贴板共享就绪"
    }
}
pub fn unavailable() -> &'static str {
    if wayland() {
        "Wayland 后台剪贴板不可用，桌面未提供可用的控制权限"
    } else {
        "X11 剪贴板服务不可用"
    }
}
pub enum Reader {
    X11(x11::Reader),
    Wayland(wl::Reader),
}
impl Reader {
    pub fn new() -> ResultType<Self> {
        Ok(if wayland() {
            Self::Wayland(wl::Reader::new()?)
        } else {
            Self::X11(x11::Reader::new()?)
        })
    }
    pub fn fd(&self) -> RawFd {
        match self {
            Self::X11(v) => v.fd(),
            Self::Wayland(v) => v.fd(),
        }
    }
    pub fn more(&self) -> bool {
        match self {
            Self::X11(v) => v.more(),
            Self::Wayland(v) => v.more(),
        }
    }
    pub fn changed(&mut self) -> ResultType<bool> {
        match self {
            Self::X11(v) => v.changed(),
            Self::Wayland(v) => v.changed(),
        }
    }
    pub fn read(
        &mut self,
        policy: Policy,
        valid: impl Fn() -> bool,
        pump: impl FnMut(),
    ) -> ResultType<Vec<Part<Bytes>>> {
        match self {
            Self::X11(v) => v.read(policy, valid, pump),
            Self::Wayland(v) => v.read(policy, valid, pump),
        }
    }
}
pub enum Writer {
    X11(x11::Writer),
    Wayland(wl::Writer),
}
impl Writer {
    pub fn new() -> ResultType<Self> {
        Ok(if wayland() {
            Self::Wayland(wl::Writer::new()?)
        } else {
            Self::X11(x11::Writer::new()?)
        })
    }
    pub fn more(&self) -> bool {
        match self {
            Self::X11(v) => v.more(),
            Self::Wayland(v) => v.more(),
        }
    }
    pub fn empty(&self) -> bool {
        match self {
            Self::X11(v) => v.empty(),
            Self::Wayland(v) => v.empty(),
        }
    }
    pub fn deadline(&self) -> Option<Instant> {
        match self {
            Self::X11(v) => v.deadline(),
            Self::Wayland(v) => v.deadline(),
        }
    }
    pub fn dispatch(&mut self) -> ResultType<()> {
        match self {
            Self::X11(v) => v.dispatch(),
            Self::Wayland(v) => v.dispatch(),
        }
    }
    pub fn poll_fds(&self, fds: &mut Vec<libc::pollfd>) {
        match self {
            Self::X11(v) => fds.push(libc::pollfd {
                fd: v.fd(),
                events: libc::POLLIN,
                revents: 0,
            }),
            Self::Wayland(v) => v.poll_fds(fds),
        }
    }
    pub fn set(&mut self, parts: Vec<Part<Bytes>>, valid: impl Fn() -> bool) -> ResultType<()> {
        match self {
            Self::X11(v) => v.set(parts, valid),
            Self::Wayland(v) => v.set(parts, valid),
        }
    }
}
