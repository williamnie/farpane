//! Driver enabled exclusively by the private container test release.
use adw::prelude::*;
use farpane_protocol::{Command, Role, ViewerConfiguration};
use gtk::glib;
use std::{
    cell::RefCell,
    collections::HashSet,
    rc::Rc,
    time::{Duration, Instant},
};
fn widget(root: &gtk::Widget, name: &str) -> Option<gtk::Widget> {
    if root.widget_name() == name {
        return Some(root.clone());
    }
    let mut child = root.first_child();
    while let Some(w) = child {
        if let Some(button) = widget(&w, name) {
            return Some(button);
        }
        child = w.next_sibling();
    }
    None
}
fn find(root: &gtk::Widget, name: &str) -> Option<gtk::Button> {
    widget(root, name)?.downcast().ok()
}
pub fn attach(ui: &Rc<crate::host::Ui>, window: &adw::ApplicationWindow) {
    let Some(directory) = crate::viewer::test_directory("FARPANE_FILES_SMOKE_DIR") else {
        return;
    };
    let ui = Rc::downgrade(ui);
    let window = window.downgrade();
    let began = Instant::now();
    let view = RefCell::new(None::<Rc<crate::file_view::View>>);
    let mut stage = 0;
    let mut passwords = 0;
    let mut approved = HashSet::new();
    let matrix = std::env::var("FARPANE_NATIVE_TEST_MODE").as_deref() == Ok("files-matrix");
    let tree = std::env::var("FARPANE_NATIVE_TEST_MODE").as_deref() == Ok("files-tree");
    let fault = std::env::var("FARPANE_NATIVE_TEST_MODE").as_deref() == Ok("files-tree-fault");
    let mut revoked = false;
    let mut overwrite_checks = 0;
    let mut rejected = None;
    glib::timeout_add_local(Duration::from_millis(100), move || {
        let (Some(ui), Some(window)) = (ui.upgrade(), window.upgrade()) else {
            return glib::ControlFlow::Break;
        };
        let result = (|| -> Result<bool, String> {
            if began.elapsed() > Duration::from_secs(50) {
                return Err(format!("File UI stage {stage} timed out"));
            }
            let s = ui.model.borrow().snapshot.clone();
            if stage == 0 {
                if s.role != Some(Role::Agent) {
                    return Ok(false);
                }
                let v = crate::file_view::open(
                    window.upcast_ref(),
                    if matrix || fault {
                        "127.0.0.1:21119"
                    } else {
                        "127.0.0.1:21118"
                    }
                    .into(),
                    ViewerConfiguration {
                        local_id: s.local_id,
                        server: s.server,
                    },
                )
                .map_err(|e| e.to_string())?;
                *view.borrow_mut() = Some(v);
                stage = 1;
                return Ok(false);
            }
            let v = view.borrow().as_ref().unwrap().clone();
            if v.auth.is_visible() {
                if std::env::var("FARPANE_NATIVE_TEST_MODE").as_deref() == Ok("files-secrets") {
                    v.secrets.save.set_active(true);
                }
                if v.challenge.get() == 3 {
                    v.submit.emit_clicked();
                } else if v.challenge.get() == 1 {
                    v.password.set_text(if passwords == 0 {
                        "wrong-file-password"
                    } else {
                        "native-viewer-smoke"
                    });
                    passwords += 1;
                    v.submit.emit_clicked();
                }
            }
            let event = v
                .events
                .borrow()
                .iter()
                .rev()
                .find(|e| e["event"]["type"] == "directory")
                .cloned();
            let completed = |id: i32| {
                v.jobs
                    .borrow()
                    .iter()
                    .any(|j| j.0 == id && j.2 == "completed")
            };
            if matches!(
                stage,
                3 | 4 | 11 | 14 | 20 | 21 | 22 | 23 | 24 | 25 | 30 | 31 | 33 | 34
            ) {
                for task in s.file_tasks.iter().filter(|t| t.needs_confirmation) {
                    if approved.contains(&task.job) {
                        continue;
                    }
                    if task.overwrite_required {
                        return Err("Unexpected overwrite in new-file roundtrip".into());
                    }
                    if let Some(button) =
                        find(window.upcast_ref(), &format!("file-allow-{}", task.job))
                    {
                        if button.is_sensitive() {
                            button.emit_clicked();
                            approved.insert(task.job);
                            break;
                        }
                    }
                }
            }
            match stage {
                1 if event
                    .as_ref()
                    .is_some_and(|e| e["event"]["data"]["page"] == 0) =>
                {
                    let event = event.unwrap();
                    if event["event"]["data"]["entries"].as_array().unwrap().len() != 128
                        || event["event"]["data"]["more"] != true
                    {
                        return Err("Initial directory was not a bounded page".into());
                    }
                    if !v.next.is_sensitive() {
                        return Ok(false);
                    }
                    v.next.emit_clicked();
                    stage = 2;
                }
                2 if event
                    .as_ref()
                    .is_some_and(|e| e["event"]["data"]["page"] == 1) =>
                {
                    v.upload_path(&directory.join("upload.bin"));
                    stage = 3;
                }
                3 if completed(1) => {
                    v.download_to("upload.bin", &directory.join("downloads"));
                    stage = 4;
                }
                4 if completed(2) => {
                    v.upload_path(&directory.join("cancel.bin"));
                    stage = 5;
                }
                5 => {
                    if s.file_tasks
                        .iter()
                        .any(|t| t.needs_confirmation && t.name.ends_with("cancel.bin"))
                        && v.jobs.borrow().iter().any(|j| j.0 == 3)
                    {
                        v.send(Command::CancelTransfer { job: 3 });
                        stage = 6;
                    }
                }
                6 if v
                    .jobs
                    .borrow()
                    .iter()
                    .any(|j| j.0 == 3 && j.2 == "cancelled")
                    && s.file_tasks
                        .iter()
                        .any(|t| t.name.ends_with("cancel.bin") && t.status == "cancelled") =>
                {
                    v.capture_smoke(&directory.join("files-window.png"))?;
                    if fault {
                        v.download_item("changing", &directory.join("downloads"), true);
                        stage = 30;
                        return Ok(false);
                    }
                    if tree {
                        v.upload_folder(&directory.join("tree"));
                        stage = 20;
                        return Ok(false);
                    }
                    if matrix {
                        v.upload_path(&directory.join("replacement/upload.bin"));
                    } else {
                        v.close();
                    }
                    stage = 7;
                }
                7 if !matrix && v.exited.get() => {
                    if passwords < 2 || approved.len() != 2 {
                        return Err(format!(
                            "Missing auth/Host consent: passwords={passwords},approved={}",
                            approved.len()
                        ));
                    }
                    return Ok(true);
                }
                7 | 9 if matrix => {
                    if let Some(task) = s
                        .file_tasks
                        .iter()
                        .find(|t| t.needs_confirmation && Some(t.job) != rejected)
                    {
                        if !task.overwrite_required {
                            return Err("Missing Host overwrite consent".into());
                        }
                        let Some(allow) =
                            find(window.upcast_ref(), &format!("file-allow-{}", task.job))
                        else {
                            return Ok(false);
                        };
                        let check =
                            widget(window.upcast_ref(), &format!("file-overwrite-{}", task.job))
                                .and_then(|w| w.downcast::<gtk::CheckButton>().ok())
                                .ok_or("Missing overwrite checkbox")?;
                        if !check.is_sensitive() {
                            return Ok(false);
                        }
                        if allow.is_sensitive() || check.is_active() {
                            return Err("Overwrite was pre-approved".into());
                        }
                        overwrite_checks += 1;
                        if stage == 7 {
                            rejected = Some(task.job);
                            find(window.upcast_ref(), &format!("file-reject-{}", task.job))
                                .ok_or("Missing reject button")?
                                .emit_clicked();
                            stage = 8;
                        } else {
                            check.set_active(true);
                            if !allow.is_sensitive() {
                                return Err("Explicit overwrite did not enable confirmation".into());
                            }
                            allow.emit_clicked();
                            approved.insert(task.job);
                            stage = 10;
                        }
                    }
                }
                8 if v.jobs.borrow().iter().any(|j| j.0 == 4 && j.2 == "failed")
                    && s.file_tasks
                        .iter()
                        .any(|t| Some(t.job) == rejected && t.status == "rejected")
                    && directory.join("rejected-preserved").exists() =>
                {
                    v.upload_path(&directory.join("replacement/upload.bin"));
                    stage = 9;
                }
                10 if completed(5) => {
                    v.download_to("upload.bin", &directory.join("downloads"));
                    stage = 11;
                }
                11 if v.jobs.borrow().iter().any(|j| j.0 == 6 && j.5)
                    && directory.join("local-preserved").exists() =>
                {
                    let w = v.window.upgrade().ok_or("File window closed")?;
                    find(w.upcast_ref(), "file-local-replace-6")
                        .ok_or("Missing local replace button")?
                        .emit_clicked();
                    stage = 12;
                }
                12 => {
                    let dialog = gtk::Window::list_toplevels()
                        .into_iter()
                        .filter_map(|w| w.downcast::<adw::MessageDialog>().ok())
                        .find(|d| d.heading().as_deref() == Some("替换已有文件？"));
                    if let Some(dialog) = dialog {
                        dialog.response("replace");
                        stage = 13;
                    }
                }
                13 if completed(6) => {
                    v.upload_path(&directory.join("interrupted.bin"));
                    stage = 14;
                }
                14 if s.file_tasks.iter().any(|t| {
                    t.name.ends_with("interrupted.bin") && t.done > 0 && t.done < t.total
                }) =>
                {
                    let nav = widget(window.upcast_ref(), "home-navigation")
                        .and_then(|w| w.downcast::<gtk::ListBox>().ok())
                        .ok_or("Missing navigation")?;
                    nav.select_row(nav.row_at_index(1).as_ref());
                    stage = 15;
                }
                15 => {
                    if let Some(c) = s
                        .inbound
                        .iter()
                        .find(|c| c.authorized && c.permissions.file)
                    {
                        if let Some(button) = find(
                            window.upcast_ref(),
                            &format!("inbound-revoke-file-{}", c.id),
                        ) {
                            if button.is_sensitive() {
                                button.emit_clicked();
                                revoked = true;
                                stage = 16;
                            }
                        }
                    }
                }
                16 if v.exited.get() && s.inbound.is_empty() => {
                    if !v.jobs.borrow().iter().any(|j| {
                        j.0 == 7
                            && matches!(j.2.as_str(), "cancelled" | "interrupted" | "failed")
                            && !j.5
                    }) {
                        return Err("File window retained an active task after worker exit".into());
                    }
                    let task = s
                        .file_tasks
                        .iter()
                        .find(|t| t.name.ends_with("interrupted.bin"))
                        .ok_or("Missing revoked file task")?;
                    if task.status != "cancelled" || task.done == 0 || task.done >= task.total {
                        return Err(format!(
                            "Revocation did not interrupt an active write: {task:?}"
                        ));
                    }
                    if !revoked || overwrite_checks != 2 || approved.len() != 5 {
                        return Err("Missing file matrix controls".into());
                    }
                    v.close();
                    stage = 17;
                    return Ok(true);
                }
                20 if v
                    .jobs
                    .borrow()
                    .iter()
                    .any(|j| j.0 == 4 && j.2 == "completed_with_skips") =>
                {
                    if approved.len() != 3 {
                        return Err("Folder upload required more than one consent".into());
                    }
                    v.upload_files(&[
                        directory.join("multi/a.bin"),
                        directory.join("multi/b.bin"),
                        directory.join("multi/空.bin"),
                    ]);
                    stage = 21;
                }
                21 if completed(5) => {
                    v.upload_folder(&directory.join("empty-folder"));
                    stage = 22;
                }
                22 if completed(6) => {
                    v.capture_smoke(&directory.join("tree-window.png"))?;
                    if directory.join("download-tree-ready").exists() {
                        v.download_item("tree", &directory.join("downloads"), true);
                        stage = 23;
                    }
                }
                23 if v
                    .jobs
                    .borrow()
                    .iter()
                    .any(|j| j.0 == 7 && j.2 == "completed_with_skips") =>
                {
                    if approved.len() != 6 {
                        return Err("Directory download required repeated consent".into());
                    }
                    v.download_item("empty-folder", &directory.join("downloads"), true);
                    stage = 24;
                }
                24 if completed(8) && directory.join("tree-overwrite-ready").exists() => {
                    v.download_item("tree", &directory.join("downloads"), true);
                    stage = 25;
                }
                25 if v.jobs.borrow().iter().any(|j| j.0 == 9 && j.5)
                    && directory.join("tree-local-preserved").exists() =>
                {
                    let w = v.window.upgrade().ok_or("File window closed")?;
                    find(w.upcast_ref(), "file-local-replace-9")
                        .ok_or("Missing directory replace button")?
                        .emit_clicked();
                    stage = 26;
                }
                26 => {
                    let dialog = gtk::Window::list_toplevels()
                        .into_iter()
                        .filter_map(|w| w.downcast::<adw::MessageDialog>().ok())
                        .find(|d| d.heading().as_deref() == Some("替换已有文件？"));
                    if let Some(dialog) = dialog {
                        dialog.response("replace");
                        stage = 27;
                    }
                }
                27 if v
                    .jobs
                    .borrow()
                    .iter()
                    .any(|j| j.0 == 9 && j.2 == "completed_with_skips") =>
                {
                    v.capture_smoke(&directory.join("download-tree-window.png"))?;
                    v.close();
                    stage = 28;
                }
                28 if v.exited.get() => {
                    if approved.len() != 8 || passwords < 2 {
                        return Err("Missing tree/multiple-file confirmations".into());
                    }
                    return Ok(true);
                }
                30 if v.jobs.borrow().iter().any(|j| j.0 == 4 && j.2 == "failed") => {
                    if !directory.join("source-changed").exists() || v.exited.get() {
                        return Err("Download failure ended the file connection".into());
                    }
                    v.download_item("cancel-tree", &directory.join("downloads"), true);
                    stage = 31;
                }
                31 if v
                    .jobs
                    .borrow()
                    .iter()
                    .any(|j| j.0 == 5 && j.3 > 0 && j.2 == "receiving") =>
                {
                    v.send(Command::CancelTransfer { job: 5 });
                    stage = 32;
                }
                32 if v
                    .jobs
                    .borrow()
                    .iter()
                    .any(|j| j.0 == 5 && j.2 == "cancelled") =>
                {
                    v.upload_path(&directory.join("upload-changing.bin"));
                    stage = 33;
                }
                33 if v.jobs.borrow().iter().any(|j| j.0 == 6 && j.2 == "failed") => {
                    if !directory.join("upload-source-changed").exists() || v.exited.get() {
                        return Err("Upload failure ended the file connection".into());
                    }
                    v.download_to("upload.bin", &directory.join("recovery"));
                    stage = 34;
                }
                34 if completed(7) => {
                    v.capture_smoke(&directory.join("fault-window.png"))?;
                    v.close();
                    stage = 35;
                }
                35 if v.exited.get() => {
                    if approved.len() != 6 {
                        return Err("Missing fault scenario consent".into());
                    }
                    return Ok(true);
                }
                _ => {}
            }
            if v.exited.get()
                && stage
                    < if fault {
                        35
                    } else if matrix {
                        16
                    } else if tree {
                        28
                    } else {
                        7
                    }
            {
                return Err(format!(
                    "File worker exited at stage {stage}: {}",
                    v.status.text()
                ));
            }
            Ok(false)
        })();
        let progress = serde_json::json!({"stage":stage,"password_attempts":passwords,"approved":approved.len(),"events":view.borrow().as_ref().map(|v|v.events.borrow().clone()),"jobs":view.borrow().as_ref().map(|v|v.jobs.borrow().clone()),"status":view.borrow().as_ref().map(|v|v.status.text().to_string()),"host_tasks":ui.model.borrow().snapshot.file_tasks,
            "challenge":view.borrow().as_ref().map(|v|v.challenge.get()),
            "authentication_visible":view.borrow().as_ref().map(|v|v.auth.is_visible())});
        let _ = std::fs::write(
            directory.join("files-progress.json"),
            serde_json::to_vec_pretty(&progress).unwrap(),
        );
        match result {
            Ok(false) => glib::ControlFlow::Continue,
            outcome => {
                let report = match outcome {
                    Ok(true) => {
                        let mut checks = vec![
                            "file-only-authentication",
                            "wrong-password-retry",
                            "bounded-directory-pages",
                            "actual-next-page-button",
                            "upload",
                            "download",
                            "actual-host-consent-buttons",
                            "cancel-before-consent",
                            "worker-reaped",
                        ];
                        if matrix {
                            checks.extend([
                                "host-overwrite-not-preapproved",
                                "actual-host-reject-button",
                                "actual-host-overwrite-checkbox",
                                "actual-local-overwrite-dialog",
                                "actual-file-revoke-button",
                                "active-write-revoked",
                                "exited-worker-has-no-active-ui-tasks",
                            ]);
                        }
                        if tree {
                            checks.extend([
                                "folder-upload-multiple-batches",
                                "one-folder-consent",
                                "unsupported-symlink-reported",
                                "multiple-files-one-task",
                                "empty-folder-upload",
                                "folder-download-multiple-batches",
                                "empty-folder-download",
                                "folder-download-symlink-reported",
                                "folder-download-overwrite-dialog",
                            ]);
                        }
                        if fault {
                            checks.extend([
                                "directory-source-change-fails-only-task",
                                "cancel-active-directory-download",
                                "upload-source-change-fails-only-task",
                                "same-file-worker-recovery-transfer",
                            ]);
                        }
                        serde_json::json!({"result":"pass","stage":stage,"password_attempts":passwords,"host_confirmation_buttons":approved.len(),"worker_reaped":true,"checks":checks})
                    }
                    Err(error) => serde_json::json!({"result":"fail","stage":stage,"error":error}),
                    _ => unreachable!(),
                };
                let _ = std::fs::write(
                    directory.join("files-ui.json"),
                    serde_json::to_vec_pretty(&report).unwrap(),
                );
                window.close();
                glib::ControlFlow::Break
            }
        }
    });
}
