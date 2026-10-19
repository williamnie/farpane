//! Native Linux roles. A build probe never opens user configuration.
pub(crate) mod activity;
pub(crate) mod audio;
mod clipboard_platform;
mod clipboard_wayland;
pub(crate) mod clipboard_wire;
mod clipboard_x11;
mod clipboard_x11_writer;
pub(crate) mod cm;
mod config;
pub(crate) mod control;
#[cfg(feature = "linux-gpu-media")]
pub(crate) mod decode;
mod desktop;
pub(crate) mod discovery;
mod file_host;
#[cfg(feature = "linux-gpu-media")]
pub(crate) mod file_viewer;
pub(crate) mod files;
pub(crate) mod host_clipboard;
pub(crate) mod ibus_commit;
pub(crate) mod input_retry;
pub(crate) mod paste_target;
pub(crate) mod process;
pub(crate) mod recovery;
pub(crate) mod session;
pub(crate) mod supervisor;
pub(crate) mod transport;
#[cfg(feature = "linux-gpu-media")]
pub(crate) mod viewer;
#[cfg(feature = "linux-gpu-media")]
pub(crate) mod viewer_audio;
#[cfg(test)]
mod viewer_boundary;
#[cfg(feature = "linux-gpu-media")]
pub(crate) mod viewer_clipboard;
#[cfg(feature = "linux-gpu-media")]
pub(crate) mod viewer_input;
#[cfg(feature = "linux-gpu-media")]
pub(crate) mod viewer_media;
#[cfg(feature = "linux-gpu-media")]
pub(crate) mod viewer_queue;
#[cfg(feature = "linux-gpu-media")]
pub(crate) mod viewer_ui;

pub fn run() -> hbb_common::ResultType<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [arg] if arg == "--version" => {
            println!("FarPane native core {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        [arg] if arg == "--build-info" => {
            println!(
                "{}",
                serde_json::json!({
                    "product": "FarPane",
                    "component": "native-core",
                    "protocol": 1,
                    "legacy_ui": false,
                    "gpu_host_compiled": cfg!(feature = "linux-gpu-media"),
                    "runtime_ready": false,
                })
            );
            Ok(())
        }
        #[cfg(feature = "drm")]
        [arg] if arg == "--check-bundled-media" => {
            control::verify_release()?;
            let library = scrap::drmtap_dl::get().ok_or_else(|| {
                hbb_common::anyhow::anyhow!(
                    "The release's bundled media library could not be loaded"
                )
            })?;
            // Resolves symbols and the ABI version only: no display, capture,
            // render node, user configuration or Host service is opened.
            println!(
                "{}",
                serde_json::json!({
                    "component": "native-core", "libdrmtap_version": library.version,
                    "device_opened": false,
                })
            );
            Ok(())
        }
        [arg] if arg == "--config-cli" => control::config_cli(),
        [arg] if arg == "--config-command" => control::config_command(),
        #[cfg(feature = "linux-gpu-media")]
        [arg, session] if arg == "--viewer" => viewer::run(session.parse()?),
        [arg] if arg == "--server" || arg == "--service" => {
            let root = unsafe { hbb_common::libc::geteuid() } == 0;
            if (arg == "--service") != root {
                hbb_common::bail!(
                    "The service requires root; the Host agent requires a desktop user"
                );
            }
            control::verify_release()?;
            let _owner = config::OwnerLock::acquire()?;
            config::initialize()?;
            if !root {
                cm::start()?;
                host_clipboard::start()?;
                audio::start_catalog()?;
                desktop::start();
                if let Err(error) = recovery::start() {
                    hbb_common::log::warn!("System recovery monitor could not start: {error}");
                }
                let listener = control::bind()?;
                std::thread::Builder::new()
                    .name("native-listener".into())
                    .spawn(move || {
                        if let Err(error) = control::serve(listener) {
                            hbb_common::log::error!("Native control listener failed: {error}");
                            activity::CM_READY.store(false, std::sync::atomic::Ordering::Release);
                        }
                    })?;
            }
            crate::core_main::core_main();
            Ok(())
        }
        #[cfg(feature = "hwcodec")]
        [arg] if arg == "--check-hwcodec-config" => {
            *hbb_common::config::APP_NAME.write().unwrap() = "FarPane".into();
            crate::ipc::hwcodec_process();
            Ok(())
        }
        _ => hbb_common::bail!(
            "Unsupported native role; the Viewer integration is still in development"
        ),
    }
}
