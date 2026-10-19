//! Real controls/confirmation/transaction driver, enabled only in private test releases.
use adw::prelude::*;
use gtk::glib;
use std::{
    rc::Rc,
    time::{Duration, Instant},
};

pub fn attach(
    ui: &Rc<crate::host::Ui>,
    group: &adw::PreferencesGroup,
    select: &gtk::DropDown,
    save: &gtk::Button,
    enabled: &adw::SwitchRow,
) {
    let Some(directory) = crate::viewer::test_directory("FARPANE_AUDIO_UI_SMOKE_DIR") else {
        return;
    };
    let ui = Rc::downgrade(ui);
    let group = group.downgrade();
    let (select, save, enabled) = (select.clone(), save.clone(), enabled.clone());
    let mut stage = 0;
    let mut original = None;
    let began = Instant::now();
    glib::timeout_add_local(Duration::from_millis(400), move || {
        let (Some(ui), Some(group)) = (ui.upgrade(), group.upgrade()) else {
            return glib::ControlFlow::Break;
        };
        let result = (|| -> Result<bool, String> {
            if began.elapsed() > Duration::from_secs(20) {
                return Err(format!("Audio UI stage {stage} timed out"));
            }
            let s = ui.model.borrow().snapshot.clone();
            let choose = |name: &str| -> Result<(), String> {
                let index = s
                    .audio_sources
                    .iter()
                    .position(|v| v.id == name)
                    .ok_or("Missing synthetic source")?;
                select.set_selected(index as u32 + 2);
                if !save.is_sensitive() {
                    return Err("Selected source cannot be applied".into());
                }
                save.emit_clicked();
                Ok(())
            };
            let dialog = || -> Result<adw::MessageDialog, String> {
                gtk::Window::list_toplevels()
                    .into_iter()
                    .find_map(|w| w.downcast::<adw::MessageDialog>().ok())
                    .ok_or_else(|| "Missing microphone consent dialog".into())
            };
            match stage {
                0 if s.audio_sources.len() >= 3 && select.is_sensitive() => {
                    if !s.audio_needs_selection || enabled.is_sensitive() || select.selected() != 0
                    {
                        return Err(format!("Legacy named source did not require explicit selection: pending={}, enabled={}, selected={}", s.audio_needs_selection, enabled.is_sensitive(), select.selected()));
                    }
                    original = Some(s.revision);
                    choose("synthetic_mic")?;
                    stage = 1;
                }
                1 => {
                    dialog()?.response("cancel");
                    stage = 2;
                }
                2 => {
                    if original != Some(s.revision)
                        || s.sharing.microphone
                        || !s.audio_needs_selection
                    {
                        return Err("Cancel changed microphone consent".into());
                    }
                    choose("synthetic_mic")?;
                    stage = 3;
                }
                3 => {
                    dialog()?.response("allow");
                    stage = 4;
                }
                4 if s.sharing.microphone
                    && !s.audio_needs_selection
                    && s.sharing.audio_source == "synthetic_mic"
                    && save.is_sensitive() =>
                {
                    choose("host_audio.monitor")?;
                    stage = 5;
                }
                5 if !s.sharing.microphone
                    && s.sharing.audio_source == "host_audio.monitor"
                    && enabled.is_sensitive() =>
                {
                    enabled.set_active(false);
                    stage = 6;
                }
                6 if !s.sharing.permissions.audio && enabled.is_sensitive() => {
                    enabled.set_active(true);
                    stage = 7;
                }
                7 if s.sharing.permissions.audio && enabled.is_sensitive() => return Ok(true),
                _ => {}
            }
            Ok(false)
        })();
        match result {
            Ok(false) => glib::ControlFlow::Continue,
            result => {
                let report = match result {
                    Ok(true) => {
                        serde_json::json!({"result":"pass","checks":["source-catalog","legacy-source-requires-selection","microphone-consent-dialog","cancel-no-change","explicit-consent-persists","monitor-clears-consent","audio-off-on-persists"]})
                    }
                    Err(error) => serde_json::json!({"result":"fail","stage":stage,"error":error}),
                    _ => unreachable!(),
                };
                let _ = std::fs::write(
                    directory.join("audio-ui.json"),
                    serde_json::to_vec_pretty(&report).unwrap(),
                );
                if let Some(window) = group.root().and_downcast::<gtk::Window>() {
                    window.close();
                }
                glib::ControlFlow::Break
            }
        }
    });
}

pub fn attach_revoke(ui: &Rc<crate::host::Ui>, root: &gtk::Box) {
    let (directory, clipboard) = match (
        crate::viewer::test_directory("FARPANE_REVOKE_AUDIO_SMOKE_DIR"),
        crate::viewer::test_directory("FARPANE_REVOKE_CLIPBOARD_SMOKE_DIR"),
    ) {
        (Some(directory), _) => (directory, false),
        (_, Some(directory)) => (directory, true),
        _ => return,
    };
    fn find(root: &gtk::Widget, name: &str) -> Option<gtk::Button> {
        if root.widget_name() == name {
            return root.clone().downcast().ok();
        }
        let mut child = root.first_child();
        while let Some(value) = child {
            if let Some(button) = find(&value, name) {
                return Some(button);
            }
            child = value.next_sibling();
        }
        None
    }
    let ui = Rc::downgrade(ui);
    let root = root.downgrade();
    let mut connection = None;
    let began = Instant::now();
    glib::timeout_add_local(Duration::from_millis(300), move || {
        let (Some(ui), Some(root)) = (ui.upgrade(), root.upgrade()) else {
            return glib::ControlFlow::Break;
        };
        let snapshot = ui.model.borrow().snapshot.clone();
        let mut done = false;
        if let Some(id) = connection {
            done = snapshot.inbound.iter().any(|c| {
                c.id == id
                    && c.authorized
                    && !(if clipboard {
                        c.permissions.clipboard
                    } else {
                        c.permissions.audio
                    })
            });
        } else if let Some(c) = snapshot.inbound.iter().find(|c| {
            c.authorized
                && if clipboard {
                    c.permissions.clipboard
                } else {
                    c.permissions.audio
                }
        }) {
            if let Some(button) = find(
                root.upcast_ref(),
                &format!(
                    "inbound-revoke-{}-{}",
                    if clipboard { "clipboard" } else { "audio" },
                    c.id
                ),
            ) {
                if button.is_sensitive() {
                    connection = Some(c.id);
                    button.emit_clicked();
                }
            }
        }
        if done || began.elapsed() > Duration::from_secs(10) {
            let report = serde_json::json!({"result":if done {"pass"} else {"fail"},"actual_revoke_button":connection.is_some(),"backend_permission_confirmed":done});
            let _ = std::fs::write(
                directory.join("revoke-ui.json"),
                serde_json::to_vec_pretty(&report).unwrap(),
            );
            if let Some(window) = root.root().and_downcast::<gtk::Window>() {
                window.close();
            }
            glib::ControlFlow::Break
        } else {
            glib::ControlFlow::Continue
        }
    });
}
