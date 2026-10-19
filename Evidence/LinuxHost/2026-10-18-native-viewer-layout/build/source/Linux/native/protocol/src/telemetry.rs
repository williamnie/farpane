//! Own-process, optional 1 Hz sampling. No process scanning or GTK-thread I/O.
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{self, Read},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Condvar, Mutex,
    },
    time::{Duration, Instant},
};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Resources {
    pub pid: u32,
    pub sample: u64,
    pub age_ms: u64,
    /// One fully occupied logical CPU = 100%; this is not machine-wide CPU.
    pub cpu_percent: Option<f32>,
    pub pss_kib: Option<u64>,
    pub rss_kib: Option<u64>,
    /// Private clean + private dirty. HugeTLB is listed separately.
    pub uss_kib: Option<u64>,
    pub swap_pss_kib: Option<u64>,
    pub private_hugetlb_kib: Option<u64>,
    /// Approximate snapshot, excluding the descriptor used to enumerate FDs.
    pub fds: Option<u64>,
    pub threads: Option<u32>,
}
fn bounded(path: &str) -> io::Result<String> {
    let mut value = String::new();
    fs::File::open(path)?
        .take(65537)
        .read_to_string(&mut value)?;
    if value.len() > 65536 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "proc record too large",
        ));
    }
    Ok(value)
}
fn stat(value: &str) -> Option<(u64, u64, u32)> {
    let end = value.rfind(") ")?;
    let fields: Vec<_> = value[end + 2..].split_whitespace().collect();
    Some((
        fields
            .get(11)?
            .parse::<u64>()
            .ok()?
            .checked_add(fields.get(12)?.parse().ok()?)?,
        fields.get(19)?.parse().ok()?,
        fields.get(17)?.parse().ok()?,
    ))
}
fn kib(value: &str, name: &str) -> Option<u64> {
    let mut lines = value.lines().filter_map(|line| line.strip_prefix(name));
    let mut fields = lines.next()?.split_whitespace();
    let n = fields.next()?.parse().ok()?;
    if fields.next() != Some("kB") || fields.next().is_some() || lines.next().is_some() {
        return None;
    }
    Some(n)
}
#[derive(Default)]
struct Sampler {
    previous: Option<(Instant, u64, u64)>,
}
impl Sampler {
    fn sample(&mut self) -> Resources {
        let now = Instant::now();
        let mut out = Resources {
            pid: std::process::id(),
            ..Default::default()
        };
        if let Some((ticks, start, threads)) =
            bounded("/proc/self/stat").ok().as_deref().and_then(stat)
        {
            out.threads = Some(threads);
            let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) };
            if let Some((at, last, old_start)) = self.previous {
                if hz > 0 && start == old_start && now > at {
                    out.cpu_percent = ticks.checked_sub(last).map(|delta| {
                        (delta as f64 * 100.0 / (hz as f64 * now.duration_since(at).as_secs_f64()))
                            as f32
                    });
                }
            }
            self.previous = Some((now, ticks, start));
        } else {
            self.previous = None;
        }
        if let Ok(raw) = bounded("/proc/self/smaps_rollup") {
            out.pss_kib = kib(&raw, "Pss:");
            out.rss_kib = kib(&raw, "Rss:");
            out.swap_pss_kib = kib(&raw, "SwapPss:");
            out.uss_kib = kib(&raw, "Private_Clean:")
                .zip(kib(&raw, "Private_Dirty:"))
                .and_then(|(a, b)| a.checked_add(b));
            out.private_hugetlb_kib = kib(&raw, "Private_Hugetlb:");
        }
        out.fds = fs::read_dir("/proc/self/fd").ok().and_then(|dir| {
            let mut n = 0u64;
            for entry in dir {
                entry.ok()?;
                n = n.checked_add(1)?;
            }
            n.checked_sub(1)
        });
        out
    }
}
#[derive(Default)]
struct Control {
    enabled: bool,
    stop: bool,
    epoch: u64,
    samples: u64,
    latest: Option<(Instant, Resources)>,
}
#[derive(Default)]
pub struct Monitor {
    shared: Arc<(Mutex<Control>, Condvar)>,
    started: AtomicBool,
}
impl Monitor {
    pub fn enable(&self, enabled: bool) {
        let (lock, wake) = &*self.shared;
        {
            let mut state = lock.lock().unwrap();
            if state.enabled != enabled {
                state.enabled = enabled;
                state.epoch = state.epoch.wrapping_add(1);
                state.latest = None;
            }
            wake.notify_one();
        }
        if enabled && !self.started.swap(true, Ordering::AcqRel) {
            let shared = self.shared.clone();
            if std::thread::Builder::new()
                .name("farpane-resources".into())
                .stack_size(128 * 1024)
                .spawn(move || sample_loop(shared))
                .is_err()
            {
                self.started.store(false, Ordering::Release);
            }
        }
    }
    pub fn snapshot(&self) -> Option<Resources> {
        let state = self.shared.0.lock().unwrap();
        state
            .latest
            .as_ref()
            .filter(|_| state.enabled)
            .map(|(at, value)| {
                let mut v = value.clone();
                v.age_ms = at.elapsed().as_millis().min(u64::MAX as u128) as u64;
                v
            })
    }
    pub fn samples(&self) -> u64 {
        self.shared.0.lock().unwrap().samples
    }
}
impl Drop for Monitor {
    fn drop(&mut self) {
        let mut state = self.shared.0.lock().unwrap();
        state.stop = true;
        self.shared.1.notify_one();
    }
}
fn sample_loop(shared: Arc<(Mutex<Control>, Condvar)>) {
    let (lock, wake) = &*shared;
    let mut epoch = u64::MAX;
    let mut sampler = Sampler::default();
    let mut next = Instant::now();
    loop {
        let mut state = lock.lock().unwrap();
        while !state.stop && (!state.enabled || (epoch == state.epoch && Instant::now() < next)) {
            state = if !state.enabled {
                wake.wait(state).unwrap()
            } else {
                wake.wait_timeout(state, next.saturating_duration_since(Instant::now()))
                    .unwrap()
                    .0
            };
        }
        if state.stop {
            return;
        }
        if epoch != state.epoch {
            epoch = state.epoch;
            sampler = Sampler::default();
        }
        drop(state);
        let mut sample = sampler.sample();
        let at = Instant::now();
        next = at + Duration::from_secs(1);
        let mut state = lock.lock().unwrap();
        if state.enabled && epoch == state.epoch && !state.stop {
            state.samples = state.samples.saturating_add(1);
            sample.sample = state.samples;
            state.latest = Some((at, sample));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_proc_comm_with_spaces_parentheses_and_rejects_missing_fields() {
        let raw = format!(
            "9 (name ) and space) S {}",
            (1..=19)
                .map(|n| n.to_string())
                .collect::<Vec<_>>()
                .join(" ")
        );
        assert_eq!(stat(&raw), Some((23, 19, 17)));
        assert_eq!(stat("9 (short) S 0"), None);
        assert_eq!(kib("Pss: 42 kB\nSwapPss: 2 kB\n", "Pss:"), Some(42));
        assert_eq!(kib("Pss: 42 bytes\n", "Pss:"), None);
        assert_eq!(kib("Pss: 42 kB\nPss: 99 kB\n", "Pss:"), None);
    }
    #[test]
    fn own_process_monitor_stops_and_resets_cpu_baseline() {
        let m = Monitor::default();
        assert_eq!(m.samples(), 0);
        assert!(m.snapshot().is_none());
        m.enable(true);
        let end = Instant::now() + Duration::from_secs(5);
        while m.samples() < 2 && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(20));
        }
        let s = m.snapshot().expect("sample");
        assert_eq!(s.pid, std::process::id());
        assert!(s.pss_kib.unwrap() > 0);
        assert!(s.cpu_percent.unwrap() >= 0.0);
        assert!(s.threads.unwrap() > 0);
        m.enable(false);
        let count = m.samples();
        std::thread::sleep(Duration::from_millis(1200));
        assert_eq!(m.samples(), count);
        assert!(m.snapshot().is_none());
        m.enable(true);
        let end = Instant::now() + Duration::from_secs(2);
        while m.samples() == count && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(m.snapshot().unwrap().cpu_percent, None);
    }
}
