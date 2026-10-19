//! Explicit container-only driver of the real list, dialogs and control bridge.
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
    while let Some(value) = child {
        if let Some(found) = find(&value, name) {
            return Some(found);
        }
        child = value.next_sibling();
    }
    None
}
fn click(root: &gtk::Widget, action: &str) -> Result<(), String> {
    let button = find(root, &format!("device-{action}-123456789"))
        .and_downcast::<gtk::Button>()
        .ok_or_else(|| format!("Recycled device row has no {action} button"))?;
    if !button.is_sensitive() {
        return Err("Device action is not sensitive".into());
    }
    button.emit_clicked();
    Ok(())
}
fn dialog() -> Result<adw::MessageDialog, String> {
    gtk::Window::list_toplevels()
        .into_iter()
        .find_map(|w| w.downcast::<adw::MessageDialog>().ok())
        .ok_or_else(|| "Missing actual device dialog".into())
}
pub fn attach(
    ui: &Rc<crate::host::Ui>,
    root: &gtk::Box,
    search: &gtk::SearchEntry,
    favorite: &gtk::ToggleButton,
    filtered: &gtk::FilterListModel,
) {
    if let Some(directory) = crate::viewer::test_directory("FARPANE_DEVICES_SECRET_DIR") {
        secrets(ui, root, search, filtered, directory);
        return;
    }
    let Some(directory) = crate::viewer::test_directory("FARPANE_DEVICES_SMOKE_DIR") else {
        return;
    };
    let weak_ui = Rc::downgrade(ui);
    let weak_root = root.downgrade();
    let search = search.clone();
    let favorite = favorite.clone();
    let filtered = filtered.clone();
    let mut stage = 0;
    let began = Instant::now();
    glib::timeout_add_local(Duration::from_millis(500), move || {
        let (Some(ui), Some(root)) = (weak_ui.upgrade(), weak_root.upgrade()) else {
            return glib::ControlFlow::Break;
        };
        let result = (|| -> Result<bool, String> {
            if began.elapsed() > Duration::from_secs(25) {
                return Err(format!("Device UI stage {stage} timed out"));
            }
            let values = ui.model.borrow().snapshot.devices.clone();
            match stage {
                0 if values.len() == 3 => {
                    search.set_text("书房");
                    stage = 1;
                }
                1 => {
                    if filtered.n_items() != 1 {
                        return Err("Search did not filter alias".into());
                    }
                    search.set_text("no-such-device");
                    stage = 2;
                }
                2 => {
                    if filtered.n_items() != 0 {
                        return Err("Empty search retained rows".into());
                    }
                    search.set_text("");
                    favorite.set_active(true);
                    stage = 3;
                }
                3 => {
                    if filtered.n_items() != 1 {
                        return Err("Favorites filter incorrect".into());
                    }
                    click(root.upcast_ref(), "star")?;
                    stage = 4;
                }
                4 if values.iter().any(|d| d.peer == "123456789" && !d.favorite) => {
                    favorite.set_active(false);
                    stage = 5;
                }
                5 => {
                    click(root.upcast_ref(), "edit")?;
                    stage = 6;
                }
                6 => {
                    let d = dialog()?;
                    find(d.upcast_ref(), "device-alias")
                        .and_downcast::<gtk::Entry>()
                        .ok_or("Missing alias entry")?
                        .set_text("测试工作站");
                    find(d.upcast_ref(), "device-favorite")
                        .and_downcast::<gtk::CheckButton>()
                        .ok_or("Missing favorite checkbox")?
                        .set_active(true);
                    d.response("save");
                    stage = 7;
                }
                7 if values
                    .iter()
                    .any(|d| d.peer == "123456789" && d.alias == "测试工作站" && d.favorite) =>
                {
                    search.set_text("测试工作站");
                    stage = 8;
                }
                8 => {
                    if filtered.n_items() != 1 {
                        return Err("Edited alias not searchable".into());
                    }
                    click(root.upcast_ref(), "forget")?;
                    stage = 9;
                }
                9 => {
                    dialog()?.response("forget");
                    stage = 10;
                }
                10 if !values.iter().any(|d| d.peer == "123456789") => return Ok(true),
                _ => {}
            }
            Ok(false)
        })();
        match result {
            Ok(false) => glib::ControlFlow::Continue,
            result => {
                let report = match result {
                    Ok(true) => {
                        serde_json::json!({"result":"pass","checks":["actual-list-model","alias-search","empty-filter","favorite-filter","favorite-click-persisted","edit-dialog-persisted","updated-alias-search","forget-confirmation-persisted"]})
                    }
                    Err(error) => serde_json::json!({"result":"fail","stage":stage,"error":error}),
                    _ => unreachable!(),
                };
                let _ = std::fs::write(
                    directory.join("devices-ui.json"),
                    serde_json::to_vec_pretty(&report).unwrap(),
                );
                if let Some(window) = root.root().and_downcast::<gtk::Window>() {
                    window.close();
                }
                glib::ControlFlow::Break
            }
        }
    });
}

fn secrets(
    ui: &Rc<crate::host::Ui>,
    root: &gtk::Box,
    search: &gtk::SearchEntry,
    filtered: &gtk::FilterListModel,
    directory: std::path::PathBuf,
) {
    let weak_ui = Rc::downgrade(ui);
    let weak_root = root.downgrade();
    let search = search.clone();
    let filtered = filtered.clone();
    let mut stage = 0;
    let began = Instant::now();
    glib::timeout_add_local(Duration::from_millis(400), move || {
        let (Some(ui), Some(root)) = (weak_ui.upgrade(), weak_root.upgrade()) else {
            return glib::ControlFlow::Break;
        };
        let result = (|| -> Result<bool, String> {
            if began.elapsed() > Duration::from_secs(30) {
                return Err(format!("Secret device UI stage {stage} timed out"));
            }
            let values = ui.model.borrow().snapshot.devices.clone();
            let choose = |heading: &str, response: &str| -> Result<(), String> {
                let d = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<adw::MessageDialog>().ok())
                    .find(|d| d.heading().as_deref() == Some(heading))
                    .ok_or_else(|| format!("Missing {heading} dialog"))?;
                d.response(response);
                Ok(())
            };
            let row = |action: &str| -> Result<(), String> {
                find(
                    root.upcast_ref(),
                    &format!("device-{action}-127.0.0.1:21118"),
                )
                .and_downcast::<gtk::Button>()
                .ok_or("Missing actual device button")?
                .emit_clicked();
                Ok(())
            };
            let forget_password = || -> Result<(), String> {
                let editor = gtk::Window::list_toplevels()
                    .into_iter()
                    .filter_map(|w| w.downcast::<adw::MessageDialog>().ok())
                    .find(|d| d.heading().as_deref() == Some("编辑设备"))
                    .ok_or("Missing device editor")?;
                find(editor.upcast_ref(), "device-forget-password")
                    .and_downcast::<gtk::Button>()
                    .ok_or("Missing forget password button")?
                    .emit_clicked();
                Ok(())
            };
            match stage {
                0 if values.len() == 1 => {
                    if values[0].remote_name.is_empty() {
                        return Err("Remote name missing".into());
                    }
                    search.set_text(&values[0].remote_name);
                    stage = 1;
                }
                1 => {
                    if filtered.n_items() != 1 {
                        return Err("Remote name not searchable".into());
                    }
                    row("edit")?;
                    stage = 2;
                }
                2 => {
                    forget_password()?;
                    stage = 3;
                }
                3 => {
                    choose("忘记已保存密码？", "cancel")?;
                    std::fs::write(directory.join("delete-cancelled"), b"cancelled")
                        .map_err(|e| e.to_string())?;
                    stage = 4;
                }
                4 if directory.join("cancel-verified").exists() => {
                    forget_password()?;
                    stage = 5;
                }
                5 => {
                    choose("忘记已保存密码？", "forget")?;
                    std::fs::write(directory.join("delete-requested"), b"requested")
                        .map_err(|e| e.to_string())?;
                    stage = 6;
                }
                6 if directory.join("delete-verified").exists() => {
                    if values.len() != 1 {
                        return Err("Password deletion erased history".into());
                    }
                    choose("编辑设备", "cancel")?;
                    std::fs::write(directory.join("ready-to-reseed"), b"ready")
                        .map_err(|e| e.to_string())?;
                    stage = 7;
                }
                7 if directory.join("reseeded").exists() => {
                    row("forget")?;
                    stage = 8;
                }
                8 => {
                    choose("忘记此设备？", "forget-all")?;
                    stage = 9;
                }
                9 if values.is_empty() => return Ok(true),
                _ => {}
            }
            Ok(false)
        })();
        match result {
            Ok(false) => glib::ControlFlow::Continue,
            result => {
                let report = match result {
                    Ok(true) => {
                        serde_json::json!({"result":"pass","checks":["remote-name-search","cancel-forget-password","forget-password-retains-history","forget-record-and-password"]})
                    }
                    Err(error) => serde_json::json!({"result":"fail","stage":stage,"error":error}),
                    _ => unreachable!(),
                };
                let _ = std::fs::write(
                    directory.join("devices-secrets.json"),
                    serde_json::to_vec_pretty(&report).unwrap(),
                );
                if let Some(window) = root.root().and_downcast::<gtk::Window>() {
                    window.close();
                }
                glib::ControlFlow::Break
            }
        }
    });
}
