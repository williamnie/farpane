use crate::host::Ui;
use adw::prelude::*;
use farpane_protocol::{AudioSource, Command};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

pub fn group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title("音频共享").build();
    let enabled = adw::SwitchRow::builder()
        .title("允许远端接收音频")
        .subtitle("只向获准连接共享所选设备的声音")
        .build();
    enabled.set_widget_name("host-audio-enabled");
    group.add(&enabled);
    let row = adw::ActionRow::builder().title("共享音源").build();
    let names = gtk::StringList::new(&["请选择共享音源", "自动选择系统声音"]);
    let select = gtk::DropDown::new(Some(names.clone()), None::<gtk::Expression>);
    select.set_widget_name("host-audio-source");
    select.set_valign(gtk::Align::Center);
    let save = gtk::Button::with_label("使用此音源");
    save.set_widget_name("host-audio-save");
    save.set_valign(gtk::Align::Center);
    row.add_suffix(&select);
    row.add_suffix(&save);
    group.add(&row);
    let status = adw::ActionRow::builder().title("音频状态").build();
    group.add(&status);
    let sources = Rc::new(RefCell::new(Vec::<AudioSource>::new()));
    let updating = Rc::new(Cell::new(false));
    let last = Rc::new(RefCell::new(None::<(u64, Vec<AudioSource>)>));
    let (weak_enabled, weak_select, weak_save, weak_status) = (
        enabled.downgrade(),
        select.downgrade(),
        save.downgrade(),
        status.downgrade(),
    );
    let (update, data) = (updating.clone(), sources.clone());
    ui.bind(move |s, ready| {
        update.set(true);
        if let Some(w) = weak_enabled.upgrade() {
            w.set_active(s.sharing.permissions.audio);
            w.set_sensitive(ready && !s.audio_needs_selection);
        }
        if let (Some(select), Some(save)) = (weak_select.upgrade(), weak_save.upgrade()) {
            if last.borrow().as_ref() != Some(&(s.revision, s.audio_sources.clone())) {
                *data.borrow_mut() = s.audio_sources.clone();
                let mut labels = vec!["请选择共享音源".to_string(), "自动选择系统声音".to_string()];
                labels.extend(s.audio_sources.iter().map(|d| {
                    format!(
                        "{} · {}",
                        d.name,
                        if d.microphone {
                            "麦克风"
                        } else {
                            "系统声音"
                        }
                    )
                }));
                names.splice(
                    0,
                    names.n_items(),
                    &labels.iter().map(String::as_str).collect::<Vec<_>>(),
                );
                select.set_selected(if s.audio_needs_selection {
                    0
                } else if s.sharing.audio_source.is_empty() {
                    1
                } else {
                    s.audio_sources
                        .iter()
                        .position(|d| d.id == s.sharing.audio_source)
                        .map(|i| i as u32 + 2)
                        .unwrap_or(0)
                });
                *last.borrow_mut() = Some((s.revision, s.audio_sources.clone()));
            }
            select.set_sensitive(ready && s.role == Some(farpane_protocol::Role::Agent));
            save.set_sensitive(
                ready && select.selected() > 0 && select.selected() != gtk::INVALID_LIST_POSITION,
            );
        }
        if let Some(w) = weak_status.upgrade() {
            w.set_subtitle(if s.audio_needs_selection {
                "升级前的音源需要重新选择；选择后点击使用此音源"
            } else if s.role != Some(farpane_protocol::Role::Agent) {
                "后台未运行，启动后检测音源"
            } else if !s.audio_error.is_empty() {
                "音频服务不可用；可稍后重新选择音源"
            } else if !s.sharing.audio_source.is_empty()
                && !s
                    .audio_sources
                    .iter()
                    .any(|d| d.id == s.sharing.audio_source)
            {
                "所选音源已断开，不会切换到其他设备"
            } else if !s.sharing.permissions.audio {
                "音频共享已关闭"
            } else if s.audio_capture.is_empty() {
                "等待音频连接"
            } else {
                &s.audio_capture
            });
        }
        update.set(false);
    });
    let weak_save = save.downgrade();
    select.connect_selected_notify(move |selection| {
        if let Some(save) = weak_save.upgrade() {
            save.set_sensitive(
                selection.is_sensitive()
                    && selection.selected() > 0
                    && selection.selected() != gtk::INVALID_LIST_POSITION,
            );
        }
    });
    let weak_ui = Rc::downgrade(ui);
    enabled.connect_active_notify(move |w| {
        if updating.get() {
            return;
        }
        if let Some(ui) = weak_ui.upgrade() {
            let s = ui.model.borrow().snapshot.clone();
            ui.send(Command::SetHostAudio {
                enabled: w.is_active(),
                source: s.sharing.audio_source,
                microphone: s.sharing.microphone,
                revision: s.revision,
            });
        }
    });
    crate::host_audio_smoke::attach(ui, &group, &select, &save, &enabled);
    let weak_ui = Rc::downgrade(ui);
    save.connect_clicked(move |button| {
        let Some(ui) = weak_ui.upgrade() else {
            return;
        };
        let index = select.selected();
        if index == 0 || index == gtk::INVALID_LIST_POSITION {
            return;
        }
        let selected = if index == 1 {
            None
        } else {
            sources
                .borrow()
                .get(index.saturating_sub(2) as usize)
                .cloned()
        };
        if index != 1 && selected.is_none() {
            return;
        }
        let s = ui.model.borrow().snapshot.clone();
        let command = Command::SetHostAudio {
            enabled: s.sharing.permissions.audio,
            source: selected.as_ref().map(|s| s.id.clone()).unwrap_or_default(),
            microphone: selected.as_ref().is_some_and(|s| s.microphone),
            revision: s.revision,
        };
        if let Some(source) = selected.filter(|s| s.microphone) {
            let Some(window) = button.root().and_downcast::<gtk::Window>() else {
                return;
            };
            let dialog = adw::MessageDialog::new(
                Some(&window),
                Some("共享麦克风？"),
                Some(&format!(
                    "选择“{}”会在音频共享开启时，将周围声音发送给获准连接的远端。",
                    source.name
                )),
            );
            dialog.set_widget_name("host-audio-consent");
            dialog.add_responses(&[("cancel", "取消"), ("allow", "允许此麦克风")]);
            dialog.set_default_response(Some("cancel"));
            dialog.set_close_response("cancel");
            dialog.set_response_appearance("allow", adw::ResponseAppearance::Destructive);
            let ui = Rc::downgrade(&ui);
            dialog.connect_response(None, move |_, response| {
                if response == "allow" {
                    if let Some(ui) = ui.upgrade() {
                        ui.send(command.clone());
                    }
                }
            });
            dialog.present();
        } else {
            ui.send(command);
        }
    });
    group
}
