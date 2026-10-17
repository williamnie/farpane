//! Actual widget driver, enabled only by the private container test guard.
use adw::prelude::*;
use gtk::glib;
use std::{rc::Rc, time::Duration};

fn find(widget: &gtk::Widget, name: &str) -> Option<gtk::Button> {
    if widget.widget_name() == name {
        return widget.clone().downcast().ok();
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(button) = find(&widget, name) {
            return Some(button);
        }
        child = widget.next_sibling();
    }
    None
}

pub fn attach(ui: &Rc<crate::host::Ui>, window: &adw::ApplicationWindow) {
    let Some(directory) = crate::viewer::test_directory("FARPANE_DESKTOP_SMOKE_DIR") else {
        return;
    };
    let weak = Rc::downgrade(ui);
    let window = window.downgrade();
    glib::timeout_add_local(Duration::from_millis(200), move || {
        let (Some(ui), Some(window)) = (weak.upgrade(), window.upgrade()) else {
            return glib::ControlFlow::Break;
        };
        let dialogs: Vec<_> = gtk::Window::list_toplevels()
            .into_iter()
            .filter_map(|w| w.downcast::<adw::MessageDialog>().ok())
            .filter(|d| d.is_visible())
            .collect();
        let state = ui.model.borrow().snapshot.clone();
        let controls = dialogs
            .iter()
            .find(|d| d.heading().as_deref() == Some("本机连接与权限"));
        let report = serde_json::json!({
            "pid":std::process::id(), "main_windows":window.application().map(|a|a.windows().len()),
            "connected":state.role.is_some(), "desktop":state.desktop, "inbound":state.inbound,
            "recovery":state.recovery, "recovery_label":recovery_label(window.upcast_ref()),
            "dialogs":dialogs.iter().map(|d|d.heading().map(|s|s.to_string())).collect::<Vec<_>>(),
        });
        let temporary = directory.join("desktop-progress.tmp");
        let _ = std::fs::write(&temporary, report.to_string())
            .and_then(|_| std::fs::rename(&temporary, directory.join("desktop-progress.json")));
        if let Some(dialog) = controls {
            if !state.inbound.is_empty()
                && !directory.join("connections.png").exists()
                && dialog.width() > 0
            {
                let snapshot = gtk::Snapshot::new();
                gtk::WidgetPaintable::new(Some(dialog)).snapshot(
                    &snapshot,
                    dialog.width() as f64,
                    dialog.height() as f64,
                );
                if let (Some(node), Some(renderer)) = (snapshot.to_node(), dialog.renderer()) {
                    let _ = renderer
                        .render_texture(&node, None)
                        .save_to_png(directory.join("connections.png"));
                }
            }
            for action in ["approve", "reject", "disconnect"] {
                if directory.join(action).exists() {
                    if let Some(connection) = state
                        .inbound
                        .iter()
                        .find(|c| c.authorized == (action == "disconnect"))
                    {
                        if let Some(button) = find(
                            dialog.upcast_ref(),
                            &format!("inbound-{action}-{}", connection.id),
                        ) {
                            if button.is_sensitive() {
                                let _ = std::fs::remove_file(directory.join(action));
                                button.emit_clicked();
                            }
                        }
                    }
                }
            }
        }
        if directory.join("close-dialogs").exists() {
            let _ = std::fs::remove_file(directory.join("close-dialogs"));
            for dialog in &dialogs {
                dialog.close();
            }
        }
        if directory.join("close-window").exists() {
            let _ = std::fs::remove_file(directory.join("close-window"));
            for dialog in &dialogs {
                dialog.close();
            }
            window.close();
            return glib::ControlFlow::Break;
        }
        glib::ControlFlow::Continue
    });
}

fn recovery_label(widget: &gtk::Widget) -> Option<String> {
    if widget.widget_name() == "host-recovery" {
        return widget
            .downcast_ref::<gtk::Label>()
            .map(|label| label.text().to_string());
    }
    let mut child = widget.first_child();
    while let Some(widget) = child {
        if let Some(value) = recovery_label(&widget) {
            return Some(value);
        }
        child = widget.next_sibling();
    }
    None
}
