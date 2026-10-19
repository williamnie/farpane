//! Private-compositor integration tests for the production paste function.
//! Included inside input_service only in test builds; no host input devices.
use super::input_text_via_clipboard_server;
use enigo::{Enigo, Key, KeyboardControllable};
use std::{sync::{Arc, Mutex}, time::{Duration, Instant}};
use dbus::blocking::Connection;
use std::{collections::HashSet, fs, path::PathBuf};

struct PrivateKeyboard {
    bus: Connection,
    path: dbus::Path<'static>,
    held: HashSet<u32>,
    events: Arc<Mutex<Vec<(u32, bool)>>>,
}

impl PrivateKeyboard {
    fn emit(&mut self, key: Key, down: bool) -> enigo::ResultType {
        // Use the product's uinput mapping. Only the final kernel write is
        // substituted by a private compositor call; no artificial key delay.
        let code = match key {
            Key::Raw(code) => code.checked_sub(8).expect("XKB offset") as u32,
            key => crate::server::uinput::service::map_key(&key)?.0.code() as u32,
        };
        self.bus.with_proxy("org.gnome.Mutter.RemoteDesktop", self.path.clone(), Duration::from_secs(1))
            .method_call::<(), _, _, _>("org.gnome.Mutter.RemoteDesktop.Session", "NotifyKeyboardKeycode", (code, down))?;
        if down { self.held.insert(code); } else { self.held.remove(&code); }
        self.events.lock().unwrap().push((code, down));
        Ok(())
    }
}

impl KeyboardControllable for PrivateKeyboard {
    fn as_any(&self) -> &dyn std::any::Any { self }
    fn as_mut_any(&mut self) -> &mut dyn std::any::Any { self }
    fn key_sequence(&mut self, _: &str) { panic!("Unexpected text fallback"); }
    fn key_down(&mut self, key: Key) -> enigo::ResultType { self.emit(key, true) }
    fn key_up(&mut self, key: Key) { self.emit(key, false).unwrap(); }
    fn key_click(&mut self, key: Key) { self.key_down(key).unwrap(); self.key_up(key); }
    fn get_key_state(&mut self, key: Key) -> bool {
        crate::server::uinput::service::map_key(&key)
            .is_ok_and(|(code, _)| self.held.contains(&(code.code() as u32)))
    }
}

#[test]
#[ignore = "requires a private Mutter from test-native-gnome-input.sh"]
fn private_mutter_production_paste() {
    assert!(std::path::Path::new("/.dockerenv").exists());
    assert!(!std::path::Path::new("/dev/uinput").exists());
    let directory = PathBuf::from(std::env::var_os("FARPANE_GNOME_INPUT_TEST_DIR").unwrap());
    assert!(directory.starts_with("/workspace/Build/Linux/native-gnome-input-smoke"));
    let read = || -> serde_json::Value {
        serde_json::from_slice(&fs::read(directory.join("entry.json")).unwrap()).unwrap()
    };
    assert_eq!(read()["text"], "");
    let bus = Connection::new_session().unwrap();
    let service = "org.gnome.Mutter.RemoteDesktop";
    let interface = "org.gnome.Mutter.RemoteDesktop.Session";
    let (path,): (dbus::Path<'static>,) = bus
        .with_proxy(service, "/org/gnome/Mutter/RemoteDesktop", Duration::from_secs(1))
        .method_call(service, "CreateSession", ()).unwrap();
    bus.with_proxy(service, path.clone(), Duration::from_secs(1))
        .method_call::<(), _, _, _>(interface, "Start", ()).unwrap();
    let events = Arc::new(Mutex::new(Vec::new()));
    let mut en = Enigo::new();
    en.set_is_x11(false);
    en.set_custom_keyboard(Box::new(PrivateKeyboard {
        bus, path, held: HashSet::new(), events: events.clone(),
    }));
    let mut expected = String::new();
    for (index, text) in ["中文测试", "混合A1，🙂", "é"].into_iter().enumerate() {
        // IME commits are text, even when an input-source shortcut left a
        // modifier down until a later physical key-up arrives.
        if index == 1 { en.key_down(Key::Control).unwrap(); }
        input_text_via_clipboard_server(&mut en, text);
        expected.push_str(text);
        let deadline = Instant::now() + Duration::from_secs(3);
        while read()["text"] != expected {
            assert!(Instant::now() < deadline, "Production paste did not reach focused target; emitted {:?}", events.lock().unwrap());
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    assert_eq!(events.lock().unwrap().len(), 14);
    fs::write(directory.join("gnome-input-result.json"), serde_json::to_vec_pretty(
        &serde_json::json!({"result":"pass", "production_paste_function":true,
            "production_key_mapping":true, "artificial_key_delay":false,
            "host_input_exercised":false, "network_input_exercised":false}),
    ).unwrap()).unwrap();
}

struct PrivateX11Keyboard {
    connection: x11rb::rust_connection::RustConnection,
    held: HashSet<u32>,
}
impl PrivateX11Keyboard {
    fn code(key: &Key) -> Result<u32, Box<dyn std::error::Error>> {
        Ok(match key {
            Key::Raw(code) => u32::from(*code),
            key => u32::from(crate::server::uinput::service::map_key(key)?.0.code()) + 8,
        })
    }
    fn emit(&mut self, key: Key, down: bool) -> enigo::ResultType {
        let code = Self::code(&key)?;
        x11rb::protocol::xtest::fake_input(&self.connection, if down { 2 } else { 3 },
            code.try_into()?, x11rb::CURRENT_TIME, x11rb::NONE, 0, 0, 0)?.check()?;
        if down { self.held.insert(code); } else { self.held.remove(&code); }
        Ok(())
    }
}
impl KeyboardControllable for PrivateX11Keyboard {
    fn as_any(&self) -> &dyn std::any::Any { self }
    fn as_mut_any(&mut self) -> &mut dyn std::any::Any { self }
    fn key_sequence(&mut self, _: &str) { panic!("Unexpected text fallback"); }
    fn key_down(&mut self, key: Key) -> enigo::ResultType { self.emit(key, true) }
    fn key_up(&mut self, key: Key) { self.emit(key, false).unwrap(); }
    fn key_click(&mut self, key: Key) { self.key_down(key).unwrap(); self.key_up(key); }
    fn get_key_state(&mut self, key: Key) -> bool {
        Self::code(&key).is_ok_and(|code| self.held.contains(&code))
    }
}

#[test]
#[ignore = "requires probe-native-warp.py and a fresh offline Warp"]
fn private_warp_production_paste() {
    assert!(std::path::Path::new("/.dockerenv").is_file());
    assert!(!std::path::Path::new("/dev/uinput").exists());
    assert!(!std::path::Path::new("/dev/dri").exists());
    assert_eq!(std::env::var("DISPLAY").as_deref(), Ok(":89"));
    assert_eq!(std::env::var("FARPANE_WARP_INPUT_TEST").as_deref(), Ok("1"));
    assert_eq!(std::env::var("HOME").as_deref(), Ok("/tmp/farpane-warp-home"));
    assert_eq!(crate::farpane_native::paste_target::current(),
               crate::farpane_native::paste_target::Shortcut::ControlShiftV);
    let result = PathBuf::from("/tmp/farpane-warp-home/production-paste.txt");
    assert!(!result.exists());
    let (connection, _) = x11rb::rust_connection::RustConnection::connect(None).unwrap();
    let mut en = Enigo::new();
    en.set_is_x11(false);
    en.set_custom_keyboard(Box::new(PrivateX11Keyboard { connection, held: HashSet::new() }));
    let mut expected = String::new();
    for (index, text) in ["中文测试", "控制提交混合🙂é"].into_iter().enumerate() {
        if index == 1 { en.key_down(Key::Control).unwrap(); }
        // Real clipboard ownership, modifier cleanup, focused-app selection,
        // and original paste timings; only final hardware writes use XTEST.
        input_text_via_clipboard_server(&mut en, &format!("printf '%s' '{text}' >> {}", result.display()));
        assert!(!en.get_key_state(Key::Control));
        // Submit the command after the paste. This is not an added delay inside
        // the production chord or clipboard path.
        std::thread::sleep(Duration::from_millis(200));
        en.key_click(Key::Return);
        expected.push_str(text);
        let deadline = Instant::now() + Duration::from_secs(3);
        while fs::read_to_string(&result).unwrap_or_default() != expected {
            assert!(Instant::now() < deadline, "Warp did not execute the exact committed text");
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    fs::write("/output/production-input.json", serde_json::to_vec_pretty(&serde_json::json!({
        "result":"pass", "text":expected, "production_paste_function":true,
        "normal_and_held_control":true, "target":"actual-offline-Warp",
        "final_input_backend":"private-XTEST", "network_and_root_uinput_tested":false,
    })).unwrap()).unwrap();
}
