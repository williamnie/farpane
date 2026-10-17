//! A bounded model with recycled GTK rows. The core owns all persistence.
use crate::{app::label, host::Ui};
use adw::prelude::*;
use farpane_protocol::{devices::Device, Command};
use gtk::{gio, glib};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

fn device(item: &gtk::ListItem) -> Option<Device> {
    let object = item.item()?.downcast::<glib::BoxedAnyObject>().ok()?;
    let value = object.borrow::<Device>().clone();
    Some(value)
}
fn connect(ui: &Ui, value: Device) {
    if let Some(connect) = ui.on_connect.borrow().as_ref() {
        connect(value.peer, false);
    }
}
fn edit(ui: &Rc<Ui>, parent: &gtk::Button, value: Device) {
    let Some(window) = parent.root().and_downcast::<gtk::Window>() else {
        return;
    };
    let dialog = adw::MessageDialog::new(Some(&window), Some("编辑设备"), Some(&value.peer));
    let alias = gtk::Entry::builder()
        .placeholder_text("设备别名")
        .text(&value.alias)
        .max_length(128)
        .build();
    let favorite = gtk::CheckButton::with_label("收藏设备");
    alias.set_widget_name("device-alias");
    favorite.set_widget_name("device-favorite");
    favorite.set_active(value.favorite);
    let content = gtk::Box::new(gtk::Orientation::Vertical, 12);
    content.append(&alias);
    content.append(&favorite);
    let forget_password = gtk::Button::with_label("忘记此设备的保存密码…");
    forget_password.set_widget_name("device-forget-password");
    content.append(&forget_password);
    let weak = Rc::downgrade(ui);
    let peer = value.peer.clone();
    let server = ui.model.borrow().snapshot.server.clone();
    forget_password.connect_clicked(move |button| {
        let Some(ui) = weak.upgrade() else {
            return;
        };
        let Some(window) = button.root().and_downcast::<gtk::Window>() else {
            return;
        };
        let confirm = adw::MessageDialog::new(
            Some(&window),
            Some("忘记已保存密码？"),
            Some("仅删除此设备在当前服务器范围内的保存密码，不改变远端密码、收藏或别名。"),
        );
        confirm.add_responses(&[("cancel", "取消"), ("forget", "忘记密码")]);
        confirm.set_close_response("cancel");
        confirm.set_response_appearance("forget", adw::ResponseAppearance::Destructive);
        let weak = Rc::downgrade(&ui);
        let peer = peer.clone();
        let server = server.clone();
        let parent = button.clone();
        confirm.connect_response(None, move |_, response| {
            if response != "forget" {
                return;
            }
            let Some(ui) = weak.upgrade() else {
                return;
            };
            let key = match crate::credentials::Key::new(&peer, &server) {
                Ok(key) => key,
                Err(e) => {
                    ui.notice(e);
                    return;
                }
            };
            let weak = Rc::downgrade(&ui);
            crate::credentials::interact(
                &parent,
                key,
                crate::credentials::Action::Delete,
                move |result| {
                    if let Some(ui) = weak.upgrade() {
                        ui.notice(match result {
                            Ok(_) => "已忘记此设备的保存密码",
                            Err(e) => e,
                        });
                    }
                },
            );
        });
        confirm.present();
    });
    dialog.set_extra_child(Some(&content));
    dialog.add_responses(&[("cancel", "取消"), ("save", "保存")]);
    dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("save"));
    dialog.set_close_response("cancel");
    let weak = Rc::downgrade(ui);
    // Use the revision at opening, so background changes cannot be overwritten.
    let revision = ui.model.borrow().snapshot.revision;
    dialog.connect_response(None, move |_, response| {
        if response == "save" {
            if let Some(ui) = weak.upgrade() {
                ui.send(Command::SetDevice {
                    peer: value.peer.clone(),
                    alias: alias.text().into(),
                    favorite: favorite.is_active(),
                    revision,
                });
            }
        }
    });
    dialog.present();
}
fn forget(ui: &Rc<Ui>, parent: &gtk::Button, value: Device) {
    let Some(window) = parent.root().and_downcast::<gtk::Window>() else {
        return;
    };
    let dialog = adw::MessageDialog::new(
        Some(&window),
        Some("忘记此设备？"),
        Some("将移除这台设备的连接记录、收藏和别名。可选择同时删除当前服务器范围内的保存密码。"),
    );
    dialog.add_responses(&[
        ("cancel", "取消"),
        ("forget", "只忘记记录"),
        ("forget-all", "同时忘记密码"),
    ]);
    dialog.set_response_appearance("forget", adw::ResponseAppearance::Destructive);
    dialog.set_response_appearance("forget-all", adw::ResponseAppearance::Destructive);
    dialog.set_close_response("cancel");
    let weak = Rc::downgrade(ui);
    let revision = ui.model.borrow().snapshot.revision;
    let server = ui.model.borrow().snapshot.server.clone();
    let parent = parent.clone();
    dialog.connect_response(None, move |_, response| {
        if response == "forget" || response == "forget-all" {
            if let Some(ui) = weak.upgrade() {
                let command = Command::ForgetDevice {
                    peer: value.peer.clone(),
                    revision,
                };
                if response == "forget" {
                    ui.send(command);
                    return;
                }
                let key = match crate::credentials::Key::new(&value.peer, &server) {
                    Ok(key) => key,
                    Err(e) => {
                        ui.notice(e);
                        return;
                    }
                };
                let weak = Rc::downgrade(&ui);
                crate::credentials::interact(
                    &parent,
                    key,
                    crate::credentials::Action::Delete,
                    move |result| {
                        if let Some(ui) = weak.upgrade() {
                            match result {
                                Ok(_) => {
                                    ui.notice("保存密码已删除，正在移除设备记录");
                                    ui.send(command);
                                }
                                Err(e) => ui.notice(e),
                            }
                        }
                    },
                );
            }
        }
    });
    dialog.present();
}

pub fn list(ui: &Rc<Ui>) -> gtk::Box {
    let root = gtk::Box::new(gtk::Orientation::Vertical, 12);
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    let heading = label("最近设备", "section-title");
    heading.set_hexpand(true);
    let search = gtk::SearchEntry::builder()
        .placeholder_text("搜索 ID、名称或别名")
        .build();
    let starred = gtk::ToggleButton::with_label("仅收藏");
    header.append(&heading);
    header.append(&search);
    header.append(&starred);
    root.append(&header);
    let empty = label(
        "连接成功后，设备会显示在这里。记录按当前 ID 服务器区分。",
        "muted",
    );
    empty.set_wrap(true);
    root.append(&empty);
    let store = gio::ListStore::new::<glib::BoxedAnyObject>();
    let query = Rc::new(RefCell::new(String::new()));
    let favorites = Rc::new(Cell::new(false));
    let q = query.clone();
    let f = favorites.clone();
    let filter = gtk::CustomFilter::new(move |object| {
        let Some(object) = object.downcast_ref::<glib::BoxedAnyObject>() else {
            return false;
        };
        let d = object.borrow::<Device>();
        (!f.get() || d.favorite)
            && (q.borrow().is_empty()
                || d.peer.to_lowercase().contains(q.borrow().as_str())
                || d.remote_name.to_lowercase().contains(q.borrow().as_str())
                || d.alias.to_lowercase().contains(q.borrow().as_str()))
    });
    let filtered = gtk::FilterListModel::new(Some(store.clone()), Some(filter.clone()));
    let f = filter.clone();
    search.connect_search_changed(move |search| {
        *query.borrow_mut() = search.text().trim().to_lowercase();
        f.changed(gtk::FilterChange::Different);
    });
    starred.connect_toggled(move |button| {
        favorites.set(button.is_active());
        filter.changed(gtk::FilterChange::Different);
    });
    let factory = gtk::SignalListItemFactory::new();
    let weak = Rc::downgrade(ui);
    factory.connect_setup(move |_, object| {
        let Some(item) = object.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        row.set_margin_top(8);
        row.set_margin_bottom(8);
        let text = gtk::Box::new(gtk::Orientation::Vertical, 4);
        text.set_hexpand(true);
        let title = label("", "card-title");
        title.set_ellipsize(gtk::pango::EllipsizeMode::End);
        let subtitle = label("", "muted");
        subtitle.set_ellipsize(gtk::pango::EllipsizeMode::End);
        text.append(&title);
        text.append(&subtitle);
        row.append(&text);
        for (icon, tooltip, action) in [
            ("non-starred-symbolic", "收藏 / 取消收藏", 0),
            ("document-edit-symbolic", "编辑设备别名", 1),
            ("edit-delete-symbolic", "忘记设备", 2),
            ("network-connect-symbolic", "连接此设备", 3),
        ] {
            let button = gtk::Button::from_icon_name(icon);
            button.set_tooltip_text(Some(tooltip));
            let weak_item = item.downgrade();
            let weak = weak.clone();
            button.connect_clicked(move |button| {
                let (Some(item), Some(ui)) = (weak_item.upgrade(), weak.upgrade()) else {
                    return;
                };
                let Some(value) = device(&item) else {
                    return;
                };
                match action {
                    0 => {
                        let revision = ui.model.borrow().snapshot.revision;
                        ui.send(Command::SetDevice {
                            peer: value.peer,
                            alias: value.alias,
                            favorite: !value.favorite,
                            revision,
                        });
                    }
                    1 => edit(&ui, button, value),
                    2 => forget(&ui, button, value),
                    _ => connect(&ui, value),
                }
            });
            row.append(&button);
        }
        item.set_child(Some(&row));
    });
    factory.connect_bind(|_, object| {
        let item = object.downcast_ref::<gtk::ListItem>().unwrap();
        let Some(value) = device(item) else {
            return;
        };
        let row = item.child().unwrap().downcast::<gtk::Box>().unwrap();
        let text = row.first_child().unwrap().downcast::<gtk::Box>().unwrap();
        let title = text
            .first_child()
            .unwrap()
            .downcast::<gtk::Label>()
            .unwrap();
        let subtitle = title
            .next_sibling()
            .unwrap()
            .downcast::<gtk::Label>()
            .unwrap();
        title.set_text(if value.alias.is_empty() {
            if value.remote_name.is_empty() {
                &value.peer
            } else {
                &value.remote_name
            }
        } else {
            &value.alias
        });
        let date = i64::try_from(value.last_connected)
            .ok()
            .and_then(|t| glib::DateTime::from_unix_local(t).ok())
            .and_then(|d| d.format("%Y-%m-%d %H:%M").ok())
            .map(|d| d.to_string())
            .unwrap_or_else(|| "时间未知".into());
        subtitle.set_text(&format!("{} · {}", value.peer, date));
        let star = text
            .next_sibling()
            .unwrap()
            .downcast::<gtk::Button>()
            .unwrap();
        star.set_icon_name(if value.favorite {
            "starred-symbolic"
        } else {
            "non-starred-symbolic"
        });
        let mut child = Some(star.upcast::<gtk::Widget>());
        for action in ["star", "edit", "forget", "connect"] {
            if let Some(button) = child {
                button.set_widget_name(&format!("device-{action}-{}", value.peer));
                child = button.next_sibling();
            }
        }
    });
    let selection = gtk::NoSelection::new(Some(filtered.clone()));
    let view = gtk::ListView::new(Some(selection), Some(factory));
    view.add_css_class("boxed-list");
    let weak = Rc::downgrade(ui);
    let items = filtered.clone();
    view.connect_activate(move |_, index| {
        if let (Some(ui), Some(value)) = (
            weak.upgrade(),
            items.item(index).and_downcast::<glib::BoxedAnyObject>(),
        ) {
            connect(&ui, value.borrow::<Device>().clone());
        }
    });
    let scroll = gtk::ScrolledWindow::builder()
        .child(&view)
        .height_request(280)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .build();
    root.append(&scroll);
    let weak = empty.downgrade();
    filtered.connect_items_changed(move |model, _, _, _| {
        if let Some(empty) = weak.upgrade() {
            empty.set_visible(model.n_items() == 0);
            empty.set_text("当前没有匹配的设备。连接成功后会自动记录；也可以调整搜索或收藏筛选。");
        }
    });
    let weak_store = store.downgrade();
    let weak_view = view.downgrade();
    let weak_empty = empty.downgrade();
    let previous = RefCell::new(Vec::<Device>::new());
    ui.bind(move |snapshot, ready| {
        if let Some(view) = weak_view.upgrade() {
            view.set_sensitive(ready);
        }
        if let Some(empty) = weak_empty.upgrade() {
            if let Some(error) = snapshot
                .unavailable
                .iter()
                .find(|s| s.starts_with("Device history:"))
            {
                empty.set_text(&format!("设备记录暂不可用，已有数据已保留：{error}"));
                empty.set_visible(true);
            }
        }
        if *previous.borrow() != snapshot.devices {
            if let Some(store) = weak_store.upgrade() {
                let objects: Vec<_> = snapshot
                    .devices
                    .iter()
                    .cloned()
                    .map(glib::BoxedAnyObject::new)
                    .collect();
                store.splice(0, store.n_items(), &objects);
                *previous.borrow_mut() = snapshot.devices.clone();
            }
        }
    });
    crate::devices_smoke::attach(ui, &root, &search, &starred, &filtered);
    root
}
