use hbb_common::config::Config;
use scrap::linux_gpu::Failure;
use std::sync::{Mutex, OnceLock};

#[derive(Clone, Default)]
struct Status {
    backend: &'static str,
    reason: String,
    generation: u64,
    failure: Option<Failure>,
}
fn state() -> &'static Mutex<Status> {
    static STATUS: OnceLock<Mutex<Status>> = OnceLock::new();
    STATUS.get_or_init(|| Mutex::new(Status::default()))
}
pub fn active(generation: u64, failure: Failure) {
    *state().lock().unwrap() = Status { backend: "gpu", generation, failure: Some(failure), reason: String::new() };
}
pub fn fallback(reason: &str) {
    *state().lock().unwrap() = Status { backend: "cpu", reason: reason.into(), ..Default::default() };
}
pub fn idle() { *state().lock().unwrap() = Status::default(); }
pub fn json() -> String {
    let status = state().lock().unwrap().clone();
    let failure = status.failure.as_ref().and_then(|failure| failure.lock().unwrap().clone());
    let enabled = Config::get_option("linux-gpu-media") == "Y";
    let backend = if !enabled { "disabled" } else if failure.is_some() { "cpu" }
        else if status.backend.is_empty() { "idle" } else { status.backend };
    serde_json::json!({ "enabled": enabled, "backend": backend,
        "reason": failure.as_deref().unwrap_or(&status.reason), "generation": status.generation }).to_string()
}
