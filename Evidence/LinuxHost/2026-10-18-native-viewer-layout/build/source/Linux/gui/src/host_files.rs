use crate::host::Ui;
use adw::prelude::*;
use farpane_protocol::Command;
use std::{
    cell::{Cell, RefCell},
    collections::HashSet,
    rc::Rc,
};

pub fn group(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder()
        .title("文件共享")
        .description("远端只能访问所选文件夹中的内容。更换文件夹或关闭共享会结束当前文件传输。")
        .build();
    let enabled = adw::SwitchRow::builder().title("允许文件传输").build();
    let directory = adw::EntryRow::builder().title("共享文件夹").build();
    let choose = gtk::Button::with_label("选择位置");
    choose.set_valign(gtk::Align::Center);
    choose.set_tooltip_text(Some("在所选位置使用专门的 FarPane 文件夹"));
    directory.add_suffix(&choose);
    let confirm = adw::SwitchRow::builder()
        .title("每次传输前确认")
        .active(true)
        .build();
    let save = gtk::Button::with_label("应用文件共享");
    save.set_widget_name("host-files-save");
    enabled.set_widget_name("host-files-enabled");
    directory.set_widget_name("host-files-root");
    confirm.set_widget_name("host-files-confirm");
    for row in [
        enabled.upcast_ref::<gtk::Widget>(),
        directory.upcast_ref(),
        confirm.upcast_ref(),
        save.upcast_ref(),
    ] {
        group.add(row);
    }
    let (e, d, c, s) = (
        enabled.downgrade(),
        directory.downgrade(),
        confirm.downgrade(),
        save.downgrade(),
    );
    let revision = Cell::new(None);
    ui.bind(move |snapshot, ready| {
        if let (Some(e), Some(d), Some(c), Some(s)) =
            (e.upgrade(), d.upgrade(), c.upgrade(), s.upgrade())
        {
            if revision.get() != Some(snapshot.revision) {
                e.set_active(snapshot.sharing.permissions.file);
                d.set_text(if snapshot.sharing.receive_directory.is_empty() {
                    ""
                } else {
                    &snapshot.sharing.receive_directory
                });
                c.set_active(snapshot.sharing.confirm_files);
                revision.set(Some(snapshot.revision));
            }
            s.set_sensitive(ready);
            e.set_sensitive(ready);
            d.set_sensitive(ready);
            c.set_sensitive(ready);
        }
    });
    let weak = directory.downgrade();
    choose.connect_clicked(move |button| {
        let parent = button.root().and_downcast::<gtk::Window>();
        let directory = weak.clone();
        gtk::FileDialog::builder()
            .title("选择文件共享位置")
            .build()
            .select_folder(
                parent.as_ref(),
                None::<&gtk::gio::Cancellable>,
                move |result| {
                    if let (Ok(folder), Some(row)) = (result, directory.upgrade()) {
                        if let Some(path) = folder
                            .path()
                            .and_then(|p| p.join("FarPane").to_str().map(str::to_owned))
                        {
                            row.set_text(&path);
                        }
                    }
                },
            );
    });
    let weak = Rc::downgrade(ui);
    save.connect_clicked(move |_| {
        if let Some(ui) = weak.upgrade() {
            let revision = ui.model.borrow().snapshot.revision;
            ui.send(Command::SetHostFiles {
                enabled: enabled.is_active(),
                directory: directory.text().to_string(),
                confirm: confirm.is_active(),
                revision,
            });
        }
    });
    group
}

pub fn tasks(ui: &Rc<Ui>) -> adw::PreferencesGroup {
    let group = adw::PreferencesGroup::builder().title("文件任务").build();
    let rows = gtk::Box::new(gtk::Orientation::Vertical, 8);
    group.add(&rows);
    let weak = rows.downgrade();
    let ui = Rc::downgrade(ui);
    let Some(owner) = ui.upgrade() else {
        return group;
    };
    let previous = std::cell::RefCell::new(String::new());
    let overwrites = Rc::new(RefCell::new(HashSet::new()));
    owner.bind(move |snapshot, ready| {
        let Some(rows) = weak.upgrade() else {
            return;
        };
        let key = serde_json::to_string(&(ready, &snapshot.file_tasks)).unwrap_or_default();
        if *previous.borrow() == key {
            return;
        }
        *previous.borrow_mut() = key;
        overwrites.borrow_mut().retain(|token| {
            snapshot
                .file_tasks
                .iter()
                .any(|t| t.job == *token && t.needs_confirmation && t.overwrite_required)
        });
        while let Some(child) = rows.first_child() {
            rows.remove(&child);
        }
        for task in snapshot.file_tasks.iter().rev() {
            let row = adw::ActionRow::builder().title(&task.name).build();
            row.set_use_markup(false);
            let status = match task.status.as_str() {
                "awaiting_confirmation" => "等待本机确认",
                "confirming" => "正在确认",
                "receiving" => "正在接收",
                "sending" => "正在发送",
                "completed" => "已保存",
                "completed_with_skips" => "已完成（部分对象已跳过）",
                "sent" => "已发送",
                "cancelled" => "已取消",
                "rejected" => "已拒绝",
                "failed" => "失败",
                "skipped" => "已跳过",
                "timed_out" => "已超时",
                _ => "等待传输",
            };
            row.set_subtitle(&format!(
                "{status} · {}{}",
                if task.total == 0 && task.done > 0 {
                    format!("已传输 {} 字节（总大小待确定）", task.done)
                } else {
                    format!("{} / {} 字节", task.done, task.total)
                },
                if task.detail.is_empty() {
                    String::new()
                } else {
                    format!(" · {}", task.detail)
                }
            ));
            let token = task.job;
            if task.needs_confirmation {
                let overwrite = gtk::CheckButton::with_label("允许覆盖同名文件");
                overwrite.set_widget_name(&format!("file-overwrite-{token}"));
                overwrite.set_visible(task.overwrite_required);
                overwrite.set_sensitive(ready);
                overwrite.set_active(overwrites.borrow().contains(&token));
                row.add_suffix(&overwrite);
                let allow = gtk::Button::with_label("允许");
                allow.set_valign(gtk::Align::Center);
                allow.set_sensitive(ready && (!task.overwrite_required || overwrite.is_active()));
                allow.set_widget_name(&format!("file-allow-{token}"));
                let w = allow.downgrade();
                let remembered = overwrites.clone();
                overwrite.connect_toggled(move |check| {
                    if check.is_active() {
                        remembered.borrow_mut().insert(token);
                    } else {
                        remembered.borrow_mut().remove(&token);
                    }
                    if let Some(button) = w.upgrade() {
                        button.set_sensitive(ready && check.is_active());
                    }
                });
                let u = ui.clone();
                allow.connect_clicked(move |_| {
                    if let Some(ui) = u.upgrade() {
                        ui.send(Command::ConfirmTransfer {
                            job: token,
                            accept: true,
                            overwrite: overwrite.is_active(),
                        });
                    }
                });
                row.add_suffix(&allow);
                let reject = gtk::Button::with_label("拒绝");
                reject.set_widget_name(&format!("file-reject-{token}"));
                reject.set_valign(gtk::Align::Center);
                reject.set_sensitive(ready);
                let u = ui.clone();
                reject.connect_clicked(move |_| {
                    if let Some(ui) = u.upgrade() {
                        ui.send(Command::ConfirmTransfer {
                            job: token,
                            accept: false,
                            overwrite: false,
                        });
                    }
                });
                row.add_suffix(&reject);
            } else if matches!(
                task.status.as_str(),
                "queued" | "confirming" | "transferring" | "receiving" | "sending"
            ) {
                let cancel = gtk::Button::with_label("取消");
                cancel.set_widget_name(&format!("file-cancel-{token}"));
                cancel.set_valign(gtk::Align::Center);
                cancel.set_sensitive(ready);
                let u = ui.clone();
                cancel.connect_clicked(move |_| {
                    if let Some(ui) = u.upgrade() {
                        ui.send(Command::CancelTransfer { job: token });
                    }
                });
                row.add_suffix(&cancel);
            }
            rows.append(&row);
        }
    });
    group
}
