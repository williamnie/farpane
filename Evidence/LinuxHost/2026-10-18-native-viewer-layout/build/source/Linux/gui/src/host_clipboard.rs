use crate::host::Ui;
use adw::prelude::*;
use farpane_protocol::{
    clipboard::{Directions, Policy},
    Command,
};
use std::{cell::Cell, rc::Rc};

fn direction(policy: &mut Policy, category: usize) -> &mut Directions {
    match category {
        0 => &mut policy.text,
        1 => &mut policy.rich_text,
        _ => &mut policy.image,
    }
}
pub fn group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder()
        .title("本机剪贴板")
        .description("分别允许向获准连接发送或接收内容。关闭不会清空本机已复制的内容。")
        .build();
    let updating = Rc::new(Cell::new(false));
    for (category, title) in ["文本", "富文本", "图片"].into_iter().enumerate() {
        let row = adw::ActionRow::builder().title(title).build();
        for (send, label) in [(true, "本机 → 远端"), (false, "远端 → 本机")] {
            let check = gtk::CheckButton::with_label(label);
            check.set_widget_name(&format!(
                "host-clipboard-{category}-{}",
                if send { "send" } else { "receive" }
            ));
            check.set_valign(gtk::Align::Center);
            row.add_suffix(&check);
            let weak = check.downgrade();
            let update = updating.clone();
            ui.bind(move |snapshot, ready| {
                if let Some(check) = weak.upgrade() {
                    update.set(true);
                    let mut policy = snapshot.sharing.clipboard;
                    let d = direction(&mut policy, category);
                    check.set_active(if send { d.send } else { d.receive });
                    check.set_sensitive(ready);
                    update.set(false);
                }
            });
            let weak = Rc::downgrade(ui);
            let update = updating.clone();
            check.connect_toggled(move |check| {
                if update.get() {
                    return;
                }
                if let Some(ui) = weak.upgrade() {
                    let snapshot = ui.model.borrow().snapshot.clone();
                    let mut policy = snapshot.sharing.clipboard;
                    let d = direction(&mut policy, category);
                    if send {
                        d.send = check.is_active();
                    } else {
                        d.receive = check.is_active();
                    }
                    ui.send(Command::SetHostClipboard {
                        policy,
                        revision: snapshot.revision,
                    });
                }
            });
        }
        group.add(&row);
    }
    let status = adw::ActionRow::builder().title("剪贴板状态").build();
    let weak = status.downgrade();
    ui.bind(move |snapshot, _| {
        if let Some(status) = weak.upgrade() {
            status.set_subtitle(if !snapshot.sharing.permissions.clipboard {
                "剪贴板共享已关闭"
            } else if snapshot.role != Some(farpane_protocol::Role::Agent) {
                "后台未运行，设置已保存"
            } else {
                &snapshot.clipboard_detail
            });
        }
    });
    group.add(&status);
    attach_smoke(ui, &group);
    group
}

fn attach_smoke(ui: &Rc<Ui>, group: &adw::PreferencesGroup) {
    let Some(directory) = crate::viewer::test_directory("FARPANE_HOST_CLIPBOARD_UI_DIR") else {
        return;
    };
    fn find(root: &gtk::Widget, name: &str) -> Option<gtk::CheckButton> {
        if root.widget_name() == name {
            return root.clone().downcast().ok();
        }
        let mut child = root.first_child();
        while let Some(c) = child {
            if let Some(found) = find(&c, name) {
                return Some(found);
            }
            child = c.next_sibling();
        }
        None
    }
    let ui = Rc::downgrade(ui);
    let group = group.downgrade();
    let began = std::time::Instant::now();
    let mut stage = 0;
    let mut waiting = None;
    let mut original = None;
    gtk::glib::timeout_add_local(std::time::Duration::from_millis(100), move || {
        let (Some(ui), Some(group)) = (ui.upgrade(), group.upgrade()) else {
            return gtk::glib::ControlFlow::Break;
        };
        let snapshot = ui.model.borrow().snapshot.clone();
        if original.is_none() && snapshot.role.is_some() {
            original = Some(snapshot.sharing.clipboard);
        }
        if let Some((expected, revision)) = waiting {
            if snapshot.revision > revision && snapshot.sharing.clipboard == expected {
                stage += 1;
                waiting = None;
            }
        } else if stage < 12 && original.is_some() {
            let category = stage / 4;
            let send = stage % 4 < 2;
            if let Some(check) = find(
                group.upcast_ref(),
                &format!(
                    "host-clipboard-{category}-{}",
                    if send { "send" } else { "receive" }
                ),
            ) {
                if check.is_sensitive() {
                    let mut expected = snapshot.sharing.clipboard;
                    let d = direction(&mut expected, category);
                    if send {
                        d.send = !d.send;
                    } else {
                        d.receive = !d.receive;
                    }
                    waiting = Some((expected, snapshot.revision));
                    check.set_active(!check.is_active());
                }
            }
        }
        if stage == 12 || began.elapsed().as_secs() > 25 {
            let passed = stage == 12 && original == Some(snapshot.sharing.clipboard);
            let _ = std::fs::write(directory.join("host-clipboard-ui.json"), serde_json::json!({
                "result": if passed { "pass" } else { "fail" }, "transactions": stage,
                "six_actual_controls": passed, "original_policy_restored": original == Some(snapshot.sharing.clipboard)
            }).to_string());
            if let Some(window) = group.root().and_downcast::<gtk::Window>() {
                window.close();
            }
            gtk::glib::ControlFlow::Break
        } else {
            gtk::glib::ControlFlow::Continue
        }
    });
}
