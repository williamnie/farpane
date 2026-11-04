use crate::file_completion::Completion;
use adw::prelude::*;
use gtk::{gio, glib};
use std::{
    cell::{Cell, RefCell},
    collections::VecDeque,
    rc::Rc,
};

#[derive(Default)]
pub struct Presenter {
    pending: RefCell<VecDeque<(Completion, glib::WeakRef<gtk::Window>)>>,
    active: Cell<bool>,
}

impl Presenter {
    pub fn show(self: &Rc<Self>, completion: Completion, parent: &gtk::Window) {
        self.pending
            .borrow_mut()
            .push_back((completion, parent.downgrade()));
        self.next();
    }

    fn next(self: &Rc<Self>) {
        if self.active.get() {
            return;
        }
        let next = self.pending.borrow_mut().pop_front();
        let Some((completion, parent)) = next else {
            return;
        };
        let Some(parent) = parent.upgrade() else {
            self.next();
            return;
        };
        self.active.set(true);
        let mut body = if completion.receiving {
            "文件已保存到本机。"
        } else {
            "所选内容已发送到远端。"
        }
        .to_owned();
        if completion.skipped {
            body.push_str("部分内容未传输，请核对文件列表。");
        }
        if let Some(directory) = &completion.directory {
            body.push_str(&format!("\n保存位置：{}", directory.display()));
        }
        let dialog = adw::MessageDialog::new(Some(&parent), Some(completion.title()), Some(&body));
        dialog.set_body_use_markup(false);
        dialog.add_response("close", "关闭");
        if completion.receiving && completion.directory.is_some() {
            dialog.add_response("open", "打开所在文件夹");
            dialog.set_response_appearance("open", adw::ResponseAppearance::Suggested);
            dialog.set_default_response(Some("open"));
        }
        dialog.set_close_response("close");
        let weak = Rc::downgrade(self);
        dialog.connect_response(None, move |_, response| {
            if response == "open" {
                if let Some(directory) = &completion.directory {
                    let file = gio::File::for_path(directory);
                    let error_parent = parent.clone();
                    gtk::FileLauncher::new(Some(&file)).launch(
                        Some(&parent),
                        None::<&gio::Cancellable>,
                        move |result| {
                            if result.is_err() {
                                let error = adw::MessageDialog::new(
                                    Some(&error_parent),
                                    Some("无法打开所在文件夹"),
                                    Some("文件已接收成功，但保存位置可能已移动或无法访问。"),
                                );
                                error.add_response("close", "好");
                                error.set_close_response("close");
                                error.present();
                            }
                        },
                    );
                }
            }
            if let Some(presenter) = weak.upgrade() {
                presenter.active.set(false);
                presenter.next();
            }
        });
        dialog.present();
    }
}
