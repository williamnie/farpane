//! Drives actual local connection controls while the same GUI displays a Viewer.
use adw::prelude::*;
use gtk::glib;
use std::{
    rc::Rc,
    time::{Duration, Instant},
};
fn find(widget: &gtk::Widget, name: &str) -> Option<gtk::Widget> {
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
pub fn attach(ui: &Rc<crate::host::Ui>, window: &adw::ApplicationWindow) {
    let Some(directory) = crate::viewer::test_directory("FARPANE_INBOUND_SMOKE_DIR") else {
        return;
    };
    let weak = Rc::downgrade(ui);
    let window = window.downgrade();
    let action = std::env::var("FARPANE_INBOUND_ACTION").unwrap_or_default();
    let mut stage = 0;
    let mut id = 0;
    let began = Instant::now();
    let mut pending_at = None;
    let mut timeout_dialog_closed = false;
    glib::timeout_add_local(Duration::from_millis(200), move || {
        let (Some(ui), Some(window)) = (weak.upgrade(), window.upgrade()) else {
            return glib::ControlFlow::Break;
        };
        let result = (|| -> Result<bool, String> {
            if began.elapsed() > Duration::from_secs(42) {
                return Err(format!("Inbound stage {stage} timed out"));
            }
            let snapshot = ui.model.borrow().snapshot.clone();
            let dialog = gtk::Window::list_toplevels()
                .into_iter()
                .filter_map(|w| w.downcast::<adw::MessageDialog>().ok())
                .find(|d| d.heading().as_deref() == Some("本机连接与权限"));
            if stage == 9 && action == "timeout" && dialog.as_ref().is_none_or(|d| !d.is_visible())
            {
                timeout_dialog_closed = true;
            }
            let click = |name: &str| -> Result<bool, String> {
                let Some(dialog) = &dialog else {
                    return Err("Missing connection controls dialog".into());
                };
                let Some(button) = find(dialog.upcast_ref(), name).and_downcast::<gtk::Button>()
                else {
                    return Ok(false);
                };
                if !button.is_sensitive() {
                    return Ok(false);
                }
                button.emit_clicked();
                Ok(true)
            };
            let progress = std::fs::read(directory.join("viewer-progress.json"))
                .ok()
                .and_then(|v| serde_json::from_slice::<serde_json::Value>(&v).ok());
            let framed = directory.join("viewer-window.png").exists();
            match stage {
                0 => {
                    if let Some(button) =
                        find(window.upcast_ref(), "inbound-manager").and_downcast::<gtk::Button>()
                    {
                        button.emit_clicked();
                        stage = 1;
                    }
                }
                1 if snapshot.inbound.len() == 1 => {
                    let c = &snapshot.inbound[0];
                    if c.authorized || framed {
                        return Err("Connection presented before approval".into());
                    }
                    id = c.id;
                    if pending_at.is_none() {
                        pending_at = Some(Instant::now());
                    }
                    if let Some(dialog) = &dialog {
                        if !directory.join("inbound-controls.png").exists() && dialog.width() > 0 {
                            let snapshot = gtk::Snapshot::new();
                            gtk::WidgetPaintable::new(Some(dialog)).snapshot(
                                &snapshot,
                                dialog.width() as f64,
                                dialog.height() as f64,
                            );
                            if let (Some(node), Some(renderer)) =
                                (snapshot.to_node(), dialog.renderer())
                            {
                                let _ = renderer
                                    .render_texture(&node, None)
                                    .save_to_png(directory.join("inbound-controls.png"));
                            }
                        }
                    }
                    if !directory.join("inbound-controls.png").exists() {
                        return Ok(false);
                    }
                    let command = match action.as_str() {
                        "approve" => "approve",
                        "reject" => "reject",
                        "timeout" => {
                            if let Some(dialog) = dialog {
                                dialog.close();
                            }
                            stage = 9;
                            return Ok(false);
                        }
                        _ => return Err("Unknown inbound action".into()),
                    };
                    if click(&format!("inbound-{command}-{id}"))? {
                        stage = if action == "approve" { 2 } else { 9 };
                    }
                }
                2 if snapshot.inbound.iter().any(|c| c.id == id && c.authorized) && framed => {
                    if click(&format!("inbound-revoke-keyboard-{id}"))? {
                        stage = 3;
                    }
                }
                3 if snapshot
                    .inbound
                    .iter()
                    .any(|c| c.id == id && !c.permissions.keyboard) =>
                {
                    let revoked = progress
                        .as_ref()
                        .and_then(|p| p["events"].as_array())
                        .is_some_and(|events| {
                            events.iter().any(|e| {
                                e["event"]["type"] == "permissions"
                                    && e["event"]["data"]["keyboard"] == false
                            })
                        });
                    if revoked && click(&format!("inbound-disconnect-{id}"))? {
                        stage = 9;
                    }
                }
                9 if snapshot.inbound.is_empty() && directory.join("viewer.json").exists() => {
                    let report: serde_json::Value = serde_json::from_slice(
                        &std::fs::read(directory.join("viewer.json")).map_err(|e| e.to_string())?,
                    )
                    .map_err(|e| e.to_string())?;
                    if report["worker_reaped"] != true {
                        return Err("Viewer worker not reaped".into());
                    }
                    if (report["presented"] == true) != (action == "approve") {
                        return Err("Unexpected frame acceptance".into());
                    }
                    if action == "timeout"
                        && pending_at.unwrap().elapsed() < Duration::from_secs(28)
                    {
                        return Err("Pending request ended before approval deadline".into());
                    }
                    if action == "timeout" && !timeout_dialog_closed {
                        return Err("Timeout controls remained visible".into());
                    }
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
                        serde_json::json!({"result":"pass","action":action,"stage":stage,"timeout_dialog_closed":timeout_dialog_closed,"elapsed_seconds":began.elapsed().as_secs_f64()})
                    }
                    Err(error) => {
                        serde_json::json!({"result":"fail","action":action,"stage":stage,"error":error})
                    }
                    _ => unreachable!(),
                };
                let _ = std::fs::write(
                    directory.join("inbound-result.json"),
                    serde_json::to_vec_pretty(&report).unwrap(),
                );
                for w in gtk::Window::list_toplevels() {
                    if let Ok(d) = w.downcast::<adw::MessageDialog>() {
                        d.close();
                    }
                }
                window.close();
                glib::ControlFlow::Break
            }
        }
    });
}
