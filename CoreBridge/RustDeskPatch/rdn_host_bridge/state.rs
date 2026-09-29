#[repr(C)]
#[derive(Clone, Copy)]
pub enum RdnHostState {
    Created = 0,
    Starting = 1,
    Ready = 2,
    Stopping = 3,
    Stopped = 4,
    Error = 5,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum HostRecoveryState {
    Running,
    Suspending,
    Suspended,
    Resuming,
    Failed,
}

impl HostRecoveryState {
    fn name(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Suspending => "suspending",
            Self::Suspended => "suspended",
            Self::Resuming => "resuming",
            Self::Failed => "failed",
        }
    }
}

fn state_name(state: RdnHostState) -> &'static str {
    match state {
        RdnHostState::Created => "created",
        RdnHostState::Starting => "starting",
        RdnHostState::Ready => "ready",
        RdnHostState::Stopping => "stopping",
        RdnHostState::Stopped => "stopped",
        RdnHostState::Error => "error",
    }
}

/// Single product authority for whether the current process owns an active
/// Aqua console session. macOS fails closed through the pinned CGSession
/// policy; non-macOS builds retain their existing behavior.
pub(crate) fn native_host_session_is_available() -> bool {
    #[cfg(target_os = "macos")]
    {
        crate::platform::macos::is_active_aqua_session()
    }
    #[cfg(not(target_os = "macos"))]
    {
        true
    }
}

/// Returns the exact frame-rate ceiling proven by the native hardware probe.
/// The video service uses this stable route contract while RustDesk QoS changes
/// only writer pacing in place.
pub(crate) fn native_media_max_fps() -> Option<u32> {
    let broker = MEDIA_BROKER.lock().unwrap();
    (broker.binding.is_some() && broker.capabilities.max_fps > 0)
        .then_some(broker.capabilities.max_fps)
}
