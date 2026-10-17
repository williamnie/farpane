use farpane_protocol::supervision::Activity;
use hbb_common::libc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

pub static CM_READY: AtomicBool = AtomicBool::new(false);
static FILE_OWNERS: AtomicU32 = AtomicU32::new(0);
static VIDEO_OWNERS: AtomicU32 = AtomicU32::new(0);

pub struct Guard(&'static AtomicU32);
impl Guard {
    pub fn files() -> Self {
        Self::new(&FILE_OWNERS)
    }
    pub fn video() -> Self {
        Self::new(&VIDEO_OWNERS)
    }
    fn new(counter: &'static AtomicU32) -> Self {
        counter.fetch_add(1, Ordering::AcqRel);
        Self(counter)
    }
}
impl Drop for Guard {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

pub fn monotonic_ms() -> u64 {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut time) } != 0 {
        return 0;
    }
    (time.tv_sec as u64)
        .saturating_mul(1000)
        .saturating_add(time.tv_nsec as u64 / 1_000_000)
}
pub fn snapshot() -> Option<Activity> {
    if !CM_READY.load(Ordering::Acquire) {
        return None;
    }
    let clients = super::cm::connections();
    #[cfg(feature = "linux-gpu-media")]
    let retiring = scrap::linux_gpu::has_live_resources() as u32;
    #[cfg(not(feature = "linux-gpu-media"))]
    let retiring = 0;
    Some(Activity {
        schema: 1,
        process_start: super::process::start_ticks(std::process::id()).ok()?,
        generation: super::control::generation(),
        observed_ms: monotonic_ms(),
        inbound: crate::server::AUTHED_CONNS
            .lock()
            .ok()?
            .len()
            .try_into()
            .ok()?,
        pending_approvals: clients
            .iter()
            .filter(|c| !c.authorized)
            .count()
            .try_into()
            .ok()?,
        // Each CM task owns its file work until the task has completely drained.
        file_jobs: FILE_OWNERS.load(Ordering::Acquire),
        media_owners: VIDEO_OWNERS
            .load(Ordering::Acquire)
            .saturating_add(retiring),
    })
}
