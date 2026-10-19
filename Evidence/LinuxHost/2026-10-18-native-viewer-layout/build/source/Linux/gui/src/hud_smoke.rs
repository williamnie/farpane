//! Private actual-widget HUD/diagnostics exercise; never enabled in an installed app.
// GTK uses the legacy chooser internally when portals are disabled in this
// private test. The product opens it through the supported GtkFileDialog API.
#![allow(deprecated)]
use super::View;
use adw::prelude::*;
use gtk::{gio, glib};
use std::{
    rc::Rc,
    time::{Duration, Instant},
};
pub(super) fn find(widget: &gtk::Widget, name: &str) -> Option<gtk::Widget> {
    if widget.widget_name() == name {
        return Some(widget.clone());
    }
    let mut child = widget.first_child();
    while let Some(w) = child {
        if let Some(found) = find(&w, name) {
            return Some(found);
        }
        child = w.next_sibling();
    }
    None
}
fn capture(window: &gtk::Window, path: &std::path::Path) -> Result<(), String> {
    let snapshot = gtk::Snapshot::new();
    gtk::WidgetPaintable::new(Some(window)).snapshot(
        &snapshot,
        window.width() as f64,
        window.height() as f64,
    );
    let node = snapshot.to_node().ok_or("No diagnostic render node")?;
    let renderer = window.renderer().ok_or("No diagnostic renderer")?;
    renderer
        .render_texture(&node, None)
        .save_to_png(path)
        .map_err(|e| e.to_string())
}
pub fn attach(view: &Rc<View>) {
    let Some(directory) = super::test_directory("FARPANE_HUD_SMOKE_DIR") else {
        return;
    };
    let weak = Rc::downgrade(view);
    let start = Instant::now();
    let mut stage = 0;
    let mut at = Instant::now();
    let mut refresh = Instant::now();
    let mut off_samples = 0;
    let mut off_events = 0;
    let mut core_samples = 0;
    glib::timeout_add_local(Duration::from_millis(100), move || {
        let Some(v) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        let result = (|| -> Result<bool, String> {
            if start.elapsed() > Duration::from_secs(42) {
                return Err(format!("HUD stage {stage} timed out"));
            }
            let Some(window) = v.root.root().and_downcast::<gtk::Window>() else {
                return Ok(false);
            };
            let toggle = find(v.root.upcast_ref(), "viewer-hud-toggle")
                .and_downcast::<gtk::ToggleButton>()
                .ok_or("Missing HUD toggle")?;
            let click = |root: &gtk::Widget, name: &str| -> Result<(), String> {
                let b = find(root, name)
                    .and_downcast::<gtk::Button>()
                    .ok_or_else(|| format!("Missing {name}"))?;
                b.emit_clicked();
                Ok(())
            };
            let metrics_count = || {
                v.smoke
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .events
                    .iter()
                    .filter(|e| e["event"]["type"] == "metrics")
                    .count()
            };
            let state = v.hud.snapshot();
            let diag = gtk::Window::list_toplevels()
                .into_iter()
                .filter_map(|w| w.downcast::<gtk::Window>().ok())
                .find(|w| w.title().as_deref() == Some("FarPane · 会话诊断"));
            let chooser = gtk::Window::list_toplevels()
                .into_iter()
                .filter_map(|w| w.downcast::<gtk::FileChooserDialog>().ok())
                .find(|w| w.is_visible());
            match stage {
                0 if v.smoke.borrow().as_ref().unwrap().first_paint.is_some() => {
                    if v.hud.enabled() || v.hud.samples() != 0 || metrics_count() != 0 {
                        return Err("Metrics sampled before HUD was enabled".into());
                    }
                    toggle.set_active(true);
                    at = Instant::now();
                    stage = 1;
                }
                1 => {
                    if refresh.elapsed() > Duration::from_millis(250) {
                        click(v.root.upcast_ref(), "viewer-refresh")?;
                        refresh = Instant::now();
                    }
                    if at.elapsed() > Duration::from_secs(4)
                        && state.gui.as_ref().is_some_and(|r| r.cpu_percent.is_some())
                        && state
                            .worker
                            .as_ref()
                            .and_then(|m| m.resources.as_ref())
                            .is_some_and(|r| r.cpu_percent.is_some())
                        && state.present_fps > 0.
                        && state
                            .worker
                            .as_ref()
                            .is_some_and(|m| m.decode_fps.is_some_and(|f| f > 0.))
                    {
                        core_samples = state
                            .worker
                            .as_ref()
                            .unwrap()
                            .resources
                            .as_ref()
                            .unwrap()
                            .sample;
                        std::fs::write(
                            directory.join("hud-active.json"),
                            serde_json::to_vec_pretty(&state).unwrap(),
                        )
                        .map_err(|e| e.to_string())?;
                        capture(&window, &directory.join("hud.png"))?;
                        toggle.set_active(false);
                        at = Instant::now();
                        stage = 2;
                    }
                }
                2 if at.elapsed() > Duration::from_secs(1) => {
                    off_samples = v.hud.samples();
                    off_events = metrics_count();
                    at = Instant::now();
                    stage = 3;
                }
                3 if at.elapsed() > Duration::from_secs(5) => {
                    if v.hud.samples() != off_samples
                        || metrics_count() != off_events
                        || v.hud.label.is_visible()
                    {
                        return Err("Hidden HUD continued sampling or receiving metrics".into());
                    }
                    toggle.set_active(true);
                    at = Instant::now();
                    stage = 4;
                }
                4 if at.elapsed() > Duration::from_secs(3)
                    && state
                        .worker
                        .as_ref()
                        .is_some_and(|m| m.packet_rate == Some(0.) && m.decode_fps == Some(0.))
                    && state.present_fps == 0. =>
                {
                    if state
                        .worker
                        .as_ref()
                        .unwrap()
                        .resources
                        .as_ref()
                        .unwrap()
                        .sample
                        > core_samples + 6
                    {
                        return Err("Worker kept sampling while HUD was hidden".into());
                    }
                    std::fs::write(
                        directory.join("hud-idle.json"),
                        serde_json::to_vec_pretty(&state).unwrap(),
                    )
                    .map_err(|e| e.to_string())?;
                    click(v.root.upcast_ref(), "viewer-diagnostics")?;
                    at = Instant::now();
                    stage = 5;
                }
                5 if diag.is_some() && at.elapsed() > Duration::from_secs(1) => {
                    let diag = diag.unwrap();
                    if std::env::var_os("FARPANE_HUD_LOG_FAILURE").is_some() {
                        let text = find(diag.upcast_ref(), "viewer-diagnostic-status")
                            .and_downcast::<gtk::Label>()
                            .ok_or("Missing log state")?
                            .text();
                        if !text.contains("不可用") {
                            return Err(format!("Missing log failure state: {text}"));
                        }
                    }
                    capture(&diag, &directory.join("diagnostics.png"))?;
                    click(diag.upcast_ref(), "viewer-diagnostic-export")?;
                    stage = 6;
                }
                6 if chooser.is_some() => {
                    chooser.unwrap().response(gtk::ResponseType::Cancel);
                    toggle.set_active(false);
                    at = Instant::now();
                    stage = 7;
                }
                7 if at.elapsed() > Duration::from_millis(1200) && chooser.is_none() => {
                    if directory.join("diagnostics.json").exists() {
                        return Err("Cancelled export wrote a file".into());
                    }
                    click(
                        diag.ok_or("Missing diagnostics window")?.upcast_ref(),
                        "viewer-diagnostic-export",
                    )?;
                    stage = 8;
                }
                8 if chooser.is_some() => {
                    let chooser = chooser.unwrap();
                    chooser
                        .set_current_folder(Some(&gio::File::for_path(&directory)))
                        .map_err(|e| e.to_string())?;
                    chooser.set_current_name("diagnostics.json");
                    at = Instant::now();
                    stage = 9;
                }
                9 if at.elapsed() > Duration::from_millis(700) && chooser.is_some() => {
                    chooser.unwrap().response(gtk::ResponseType::Accept);
                    stage = 10;
                }
                10 if directory.join("diagnostics.json").exists() => {
                    let raw = std::fs::read_to_string(directory.join("diagnostics.json"))
                        .map_err(|e| e.to_string())?;
                    let data: serde_json::Value =
                        serde_json::from_str(&raw).map_err(|e| e.to_string())?;
                    if data["schema"] != 1
                        || raw.contains("native-viewer-smoke")
                        || raw.contains("127.0.0.1")
                        || raw.contains("21118")
                    {
                        return Err("Invalid or sensitive diagnostic export".into());
                    }
                    if data["performance"]["gui"]["pss_kib"].as_u64().is_none()
                        || data["performance"]["worker"]["resources"]["pss_kib"]
                            .as_u64()
                            .is_none()
                        || data["performance_age_ms"].as_u64().unwrap_or(0) < 1000
                    {
                        return Err("Hidden HUD lost its last dated diagnostic sample".into());
                    }
                    v.diagnostics.export(&gio::File::for_path(
                        directory.join("missing-parent/report.json"),
                    ));
                    at = Instant::now();
                    stage = 11;
                }
                11 if at.elapsed() > Duration::from_millis(300) => {
                    let diag = diag.ok_or("Missing diagnostics window")?;
                    let text = find(diag.upcast_ref(), "viewer-diagnostic-status")
                        .and_downcast::<gtk::Label>()
                        .ok_or("Missing export status")?
                        .text();
                    if !text.contains("保存失败") {
                        return Ok(false);
                    }
                    if v.has_exited()
                        || v.model.borrow().phase != farpane_protocol::Phase::Streaming
                    {
                        return Err("Log/export error ended media".into());
                    }
                    diag.close();
                    toggle.set_active(false);
                    return Ok(true);
                }
                _ => {}
            }
            Ok(false)
        })();
        match result {
            Ok(false) => glib::ControlFlow::Continue,
            result => {
                let report = match result {
                    Ok(true) => {
                        serde_json::json!({"result":"pass","elapsed_seconds":start.elapsed().as_secs_f64(),"samples_before_hidden":off_samples,"metrics_after_hidden_drain":off_events,"checks":["no-hidden-initial-sampling","actual-hud-toggle","real-resource-counters","refresh-presented-fps","hidden-hud-stops-samples-and-events","idle-rate-zero","actual-diagnostic-window","cancel-export","actual-save-file-dialog","redacted-export","hidden-hud-keeps-aged-diagnostic-snapshot","write-failure-retains-stream"]})
                    }
                    Err(e) => serde_json::json!({"result":"fail","stage":stage,"error":e}),
                    _ => unreachable!(),
                };
                let _ = std::fs::write(
                    directory.join("hud-result.json"),
                    serde_json::to_vec_pretty(&report).unwrap(),
                );
                for w in gtk::Window::list_toplevels() {
                    if let Ok(w) = w.downcast::<gtk::Window>() {
                        if w.title().as_deref() == Some("FarPane · 会话诊断") {
                            w.close();
                        }
                    }
                }
                v.close();
                glib::ControlFlow::Break
            }
        }
    });
}
