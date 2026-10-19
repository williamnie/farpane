mod app;
mod auth_secrets;
mod bridge;
mod clipboard_provider;
mod credentials;
mod desktop_smoke;
mod devices;
mod devices_smoke;
mod diagnostics;
mod file_smoke;
mod file_view;
mod gpu_renderer;
mod host;
mod host_audio;
mod host_audio_smoke;
mod host_clipboard;
mod host_files;
mod inbound_smoke;
mod memory;
mod model;
mod viewer;
mod viewer_bridge;
mod viewer_clipboard;
mod viewer_cursor;
mod viewer_hud;
mod viewer_input;
mod viewer_recovery;

use adw::prelude::*;
use gtk::{gio, glib};

pub(crate) struct InstalledVersion {
    pub version: String,
    pub core_build: Option<String>,
}

/// Read the metadata beside this executable, never the mutable `current` link.
/// An already-open old GUI must keep showing its own installed version.
pub(crate) fn installed_version() -> &'static InstalledVersion {
    static VERSION: std::sync::OnceLock<InstalledVersion> = std::sync::OnceLock::new();
    VERSION.get_or_init(|| {
        let load = || -> Option<InstalledVersion> {
            use std::io::Read;
            let executable = std::env::current_exe().ok()?.canonicalize().ok()?;
            let file = std::fs::File::open(executable.parent()?.join("release-info.json")).ok()?;
            let value: serde_json::Value = serde_json::from_reader(file.take(4096)).ok()?;
            if value.get("schema")?.as_u64()? != 1 {
                return None;
            }
            let version = value.get("version")?.as_str()?;
            let core = value.get("core_sha256")?.as_str()?;
            if version.is_empty() || version.len() > 48
                || !version.bytes().all(|b| b.is_ascii_alphanumeric() || b".+-".contains(&b))
                || core.len() != 64 || !core.bytes().all(|b| b.is_ascii_hexdigit())
            {
                return None;
            }
            Some(InstalledVersion {
                version: version.into(),
                core_build: Some(core[..8].to_ascii_lowercase()),
            })
        };
        load().unwrap_or_else(|| InstalledVersion {
            version: format!("{} · 构建未标识", env!("CARGO_PKG_VERSION")),
            core_build: None,
        })
    })
}

fn main() -> glib::ExitCode {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() == 1 && args[0] == "--version" {
        println!("FarPane {}", installed_version().version);
        return glib::ExitCode::SUCCESS;
    }
    if args.len() == 1 && args[0] == "--build-info" {
        println!(
            "{}",
            serde_json::json!({
                "product": "FarPane", "component": "native-gui",
                "version": env!("CARGO_PKG_VERSION"),
                "protocol": farpane_protocol::VERSION,
                "gtk_minimum": "4.14", "libadwaita_minimum": "1.5",
                "runtime_ready": false,
            })
        );
        return glib::ExitCode::SUCCESS;
    }
    // GLArea produces a GL texture. Keep GTK composition on GL as well so a
    // default Vulkan/Cairo renderer cannot introduce a hidden CPU download.
    // Explicit environment overrides are honoured; their Viewer uses software.
    if std::env::var_os("GSK_RENDERER").is_none() {
        std::env::set_var("GSK_RENDERER", "gl");
    }
    gio::resources_register_include!("farpane.gresource").expect("embedded FarPane resources");
    let app = adw::Application::builder()
        .application_id("org.farpane.FarPane")
        .build();
    let shell = std::rc::Rc::new(std::cell::RefCell::new(std::rc::Weak::<app::Shell>::new()));
    let active = shell.clone();
    app.connect_activate(move |app| {
        let existing = active.borrow().upgrade();
        if let Some(shell) = existing {
            shell.present();
        } else {
            *active.borrow_mut() = std::rc::Rc::downgrade(&app::build(app));
        }
    });
    for name in ["show-home", "show-connections", "tray-menu"] {
        let action = gio::SimpleAction::new(name, None);
        let application = app.downgrade();
        let active = shell.clone();
        action.connect_activate(move |_, _| {
            let Some(app) = application.upgrade() else {
                return;
            };
            app.activate();
            if let Some(shell) = active.borrow().upgrade() {
                match name {
                    "show-connections" => shell.show_connections(),
                    "tray-menu" => shell.tray_menu(),
                    _ => shell.present(),
                }
            }
        });
        app.add_action(&action);
    }
    app.run()
}
