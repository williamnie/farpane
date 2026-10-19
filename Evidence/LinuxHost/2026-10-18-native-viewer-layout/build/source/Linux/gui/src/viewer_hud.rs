//! Only visible HUDs sample resources. GTK after-paint counts new remote images,
//! not redraws caused by the toolbar, cursor or this overlay.
use adw::prelude::*;
use farpane_protocol::{
    telemetry::{Monitor, Resources},
    Metrics,
};
use serde::Serialize;
use std::{
    cell::{Cell, RefCell},
    time::{Duration, Instant},
};

#[derive(Clone, Default, Serialize)]
pub struct Snapshot {
    pub present_fps: f32,
    pub presentation_wait_ms: Option<f32>,
    pub local_candidates_skipped: u64,
    pub gpu_loans: u32,
    pub gui: Option<Resources>,
    pub worker: Option<Metrics>,
    pub worker_sample_age_ms: Option<u64>,
}
pub struct Hud {
    pub label: gtk::Label,
    enabled: Cell<bool>,
    resources: Monitor,
    core: RefCell<Option<(Instant, Metrics)>>,
    at: Cell<Instant>,
    painted: Cell<u64>,
    previous: Cell<u64>,
    wait_sum: Cell<f64>,
    wait_count: Cell<u64>,
    latest: RefCell<Snapshot>,
    sampled_at: Cell<Option<Instant>>,
}
fn number(value: Option<f32>, digits: usize) -> String {
    value
        .filter(|v| v.is_finite())
        .map(|v| format!("{v:.digits$}"))
        .unwrap_or_else(|| "—".into())
}
fn mib(value: Option<u64>) -> String {
    value
        .map(|v| format!("{:.1}", v as f64 / 1024.))
        .unwrap_or_else(|| "—".into())
}
fn process(label: &str, value: Option<&Resources>) -> String {
    if let Some(v) = value.filter(|v| v.age_ms <= 3000) {
        format!("{label} CPU {}% · PSS {} MiB\n    USS {} · RSS {} · SwapPSS {} MiB\n    FD {} · 线程 {}",number(v.cpu_percent,1),mib(v.pss_kib),mib(v.uss_kib),mib(v.rss_kib),mib(v.swap_pss_kib),v.fds.map(|n|n.to_string()).unwrap_or_else(||"—".into()),v.threads.map(|n|n.to_string()).unwrap_or_else(||"—".into()))
    } else {
        format!("{label} CPU — · PSS —")
    }
}
impl Hud {
    pub fn new() -> Self {
        let label = crate::app::label("正在采样…", "viewer-hud");
        label.set_widget_name("viewer-hud");
        label.set_halign(gtk::Align::End);
        label.set_valign(gtk::Align::Start);
        label.set_margin_end(12);
        label.set_margin_top(12);
        label.set_visible(false);
        label.set_tooltip_text(Some("CPU 以单核满载为 100%。内存只计本 GUI 与 Viewer worker，不含 Host、文件 worker 或 GPU 专用内存。接收只计视频编码包。网络 RTT 由远端报告；本地等待从帧到达 GUI 到 GTK after-paint，不是端到端延迟。"));
        Self {
            label,
            enabled: Cell::new(false),
            resources: Default::default(),
            core: RefCell::new(None),
            at: Cell::new(Instant::now()),
            painted: Cell::new(0),
            previous: Cell::new(0),
            wait_sum: Cell::new(0.),
            wait_count: Cell::new(0),
            latest: Default::default(),
            sampled_at: Cell::new(None),
        }
    }
    pub fn enable(&self, enabled: bool) {
        self.enabled.set(enabled);
        self.label.set_visible(enabled);
        self.resources.enable(enabled);
        self.at.set(Instant::now());
        self.previous.set(self.painted.get());
        self.wait_sum.set(0.);
        self.wait_count.set(0);
        self.core.borrow_mut().take();
        *self.latest.borrow_mut() = Snapshot::default();
        self.sampled_at.set(None);
        self.label.set_text("正在采样…");
    }
    pub fn enabled(&self) -> bool {
        self.enabled.get()
    }
    pub fn samples(&self) -> u64 {
        self.resources.samples()
    }
    pub fn snapshot(&self) -> Snapshot {
        self.latest.borrow().clone()
    }
    pub fn sampled_at(&self) -> Option<Instant> {
        self.sampled_at.get()
    }
    pub fn metrics(&self, mut m: Metrics) {
        if !matches!(m.backend.as_str(), "vaapi" | "software") {
            m.backend = "unknown".into();
        }
        if !matches!(m.codec.as_str(), "H.264" | "HEVC" | "VP8" | "VP9") {
            m.codec = "unknown".into();
        }
        if self.enabled.get() {
            *self.core.borrow_mut() = Some((Instant::now(), m));
        }
    }
    pub fn presented(&self, received: Option<Instant>) {
        self.painted.set(self.painted.get().saturating_add(1));
        if self.enabled.get() {
            if let Some(at) = received {
                self.wait_sum
                    .set(self.wait_sum.get() + at.elapsed().as_secs_f64() * 1000.);
                self.wait_count.set(self.wait_count.get().saturating_add(1));
            }
        }
    }
    pub fn tick(&self, skipped: u64, gpu_loans: u32) {
        if !self.enabled.get() || self.at.get().elapsed() < Duration::from_secs(1) {
            return;
        }
        let dt = self.at.replace(Instant::now()).elapsed().as_secs_f32();
        let count = self.painted.get();
        let previous = self.previous.replace(count);
        let core = self.core.borrow();
        let age = core.as_ref().map(|(at, _)| at.elapsed().as_millis() as u64);
        let worker = core
            .as_ref()
            .filter(|(at, _)| at.elapsed() < Duration::from_secs(3))
            .map(|(at, m)| {
                let mut m = m.clone();
                if let Some(r) = &mut m.resources {
                    r.age_ms = r.age_ms.saturating_add(at.elapsed().as_millis() as u64);
                }
                m
            });
        let gui = self.resources.snapshot();
        let wait = if self.wait_count.get() > 0 {
            Some((self.wait_sum.get() / self.wait_count.get() as f64) as f32)
        } else {
            None
        };
        let snapshot = Snapshot {
            present_fps: count.saturating_sub(previous) as f32 / dt,
            presentation_wait_ms: wait,
            local_candidates_skipped: skipped,
            gpu_loans,
            gui,
            worker,
            worker_sample_age_ms: age,
        };
        self.wait_count.set(0);
        self.wait_sum.set(0.);
        let m = snapshot.worker.as_ref();
        let backend = m
            .map(|m| {
                format!(
                    "{} · {} · {}",
                    m.codec,
                    m.backend,
                    match m.relay {
                        Some(true) => "中继",
                        Some(false) => "直连",
                        None => "未知链路",
                    }
                )
            })
            .unwrap_or_else(|| "等待后台指标…".into());
        let text=format!("接收 {} 包/s · {} KiB/s\n解码 {} FPS · 呈现 {:.1} FPS\n解码调用 {} ms/帧\n网络 RTT {} ms · 本地等待 {} ms\n候选未呈现 {} · GPU 租约 {}\n压缩待处理 {} 项 / {} KiB\n{}\n{}\n{}",
            number(m.and_then(|m|m.packet_rate),1),number(m.and_then(|m|m.receive_kib_per_sec),1),number(m.and_then(|m|m.decode_fps),1),snapshot.present_fps,
            number(m.and_then(|m|m.decode_ms),2),m.and_then(|m|m.delay_ms).map(|n|n.to_string()).unwrap_or_else(||"—".into()),number(wait,2),skipped,gpu_loans,
            m.map(|m|m.queued_groups.to_string()).unwrap_or_else(||"—".into()),m.map(|m|format!("{:.1}",m.queue_bytes as f64/1024.)).unwrap_or_else(||"—".into()),process("GUI",snapshot.gui.as_ref()),process("Viewer",m.and_then(|m|m.resources.as_ref())),backend);
        self.label.set_text(&text);
        *self.latest.borrow_mut() = snapshot;
        self.sampled_at.set(Some(Instant::now()));
    }
}
