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

fn main() -> glib::ExitCode {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() == 1 && args[0] == "--version" {
        println!("FarPane {}", env!("CARGO_PKG_VERSION"));
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
