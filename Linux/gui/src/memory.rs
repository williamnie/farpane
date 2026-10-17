//! Return transient GTK/driver startup allocations while the Home is idle.
//! This never discards live textures, trims a decoder, or runs a periodic scan.
use std::sync::atomic::{AtomicBool, Ordering};

static RUNNING: AtomicBool = AtomicBool::new(false);

pub fn reclaim_idle() {
    if RUNNING.swap(true, Ordering::AcqRel) {
        return;
    }
    // malloc_trim is thread-safe on the supported glibc distributions. Keep
    // its allocator walk off GTK's main thread; only one request can run.
    let result = std::thread::Builder::new()
        .name("farpane-reclaim".into())
        .stack_size(128 * 1024)
        .spawn(|| {
            #[cfg(target_env = "gnu")]
            unsafe {
                libc::malloc_trim(0);
            }
            RUNNING.store(false, Ordering::Release);
        });
    if result.is_err() {
        RUNNING.store(false, Ordering::Release);
    }
}
