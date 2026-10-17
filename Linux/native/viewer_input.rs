//! Remote input translation. No local X11, rdev, global keyboard hook, or Host IPC.
use base::message_proto::{ControlKey, KeyEvent, Message, MouseEvent};
use farpane_protocol::{Display, Input, PointerAction};
use hbb_common::{bail, ResultType};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Default)]
pub struct State {
    keys: BTreeMap<u32, KeyEvent>,
    buttons: BTreeSet<u8>,
    position: (i32, i32),
    modifiers: u32,
    scroll: (f64, f64),
}
fn modifiers(bits: u32) -> Vec<hbb_common::protobuf::EnumOrUnknown<ControlKey>> {
    [
        (1, ControlKey::Shift),
        (2, ControlKey::Control),
        (4, ControlKey::Alt),
        (8, ControlKey::Meta),
        (16, ControlKey::CapsLock),
        (32, ControlKey::NumLock),
    ]
    .into_iter()
    .filter_map(|(mask, key)| (bits & mask != 0).then_some(key.into()))
    .collect()
}
fn mouse(mask: i32, x: i32, y: i32, bits: u32) -> Message {
    let mut message = Message::new();
    message.set_mouse_event(MouseEvent {
        mask,
        x,
        y,
        modifiers: modifiers(bits),
        ..Default::default()
    });
    message
}
fn key_message(event: KeyEvent) -> Message {
    let mut message = Message::new();
    message.set_key_event(event);
    message
}
fn key(keyval: u32) -> Option<KeyEvent> {
    use ControlKey::*;
    let special = match keyval {
        0xff08 => Some(Backspace),
        0xff09 | 0xfe20 => Some(Tab),
        0xff0d => Some(Return),
        0xff1b => Some(Escape),
        0xffff => Some(Delete),
        0xff63 => Some(Insert),
        0xff50 => Some(Home),
        0xff57 => Some(End),
        0xff51 => Some(LeftArrow),
        0xff52 => Some(UpArrow),
        0xff53 => Some(RightArrow),
        0xff54 => Some(DownArrow),
        0xff55 => Some(PageUp),
        0xff56 => Some(PageDown),
        0xffe1 => Some(Shift),
        0xffe2 => Some(RShift),
        0xffe3 => Some(Control),
        0xffe4 => Some(RControl),
        0xffe9 => Some(Alt),
        0xffea | 0xfe03 => Some(RAlt),
        0xffeb | 0xffe7 => Some(Meta),
        0xffec | 0xffe8 => Some(RWin),
        0xffe5 => Some(CapsLock),
        0xff7f => Some(NumLock),
        0xff14 => Some(Scroll),
        0xff13 => Some(Pause),
        0xff61 => Some(Snapshot),
        0xff67 => Some(Apps),
        0xff8d => Some(NumpadEnter),
        0xffaa => Some(Multiply),
        0xffab => Some(Add),
        0xffad => Some(Subtract),
        0xffae => Some(Decimal),
        0xffaf => Some(Divide),
        0xffbd => Some(Equals),
        0xffbe..=0xffc9 => {
            Some([F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12][(keyval - 0xffbe) as usize])
        }
        0xffb0..=0xffb9 => Some(
            [
                Numpad0, Numpad1, Numpad2, Numpad3, Numpad4, Numpad5, Numpad6, Numpad7, Numpad8,
                Numpad9,
            ][(keyval - 0xffb0) as usize],
        ),
        _ => None,
    };
    let mut event = KeyEvent::new();
    if let Some(special) = special {
        event.set_control_key(special);
    } else if (0x20..=0xff).contains(&keyval) {
        event.set_chr(keyval);
    } else {
        return None;
    } // Other Unicode text is committed once through GTK IME.
    Some(event)
}
impl State {
    pub fn translate(
        &mut self,
        input: Input,
        display: Option<&Display>,
    ) -> ResultType<Vec<Message>> {
        let mut out = Vec::new();
        match input {
            Input::ReleaseAll => {
                for (_, mut event) in std::mem::take(&mut self.keys) {
                    event.down = false;
                    event.modifiers.clear();
                    out.push(key_message(event));
                }
                for button in std::mem::take(&mut self.buttons) {
                    out.push(mouse(
                        (button as i32) << 3 | 2,
                        self.position.0,
                        self.position.1,
                        0,
                    ));
                }
                self.modifiers = 0;
                self.scroll = (0., 0.);
            }
            Input::Key {
                keyval,
                hardware_code,
                pressed,
                modifiers: bits,
            } => {
                if hardware_code > 65535 || bits & !63 != 0 {
                    bail!("Invalid keyboard event");
                }
                self.modifiers = bits;
                let token = if hardware_code == 0 {
                    keyval
                } else {
                    hardware_code
                };
                if pressed {
                    if self.keys.len() >= 256 && !self.keys.contains_key(&token) {
                        bail!("Too many pressed keys");
                    }
                    if let Some(mut event) = self.keys.get(&token).cloned().or_else(|| key(keyval))
                    {
                        event.down = true;
                        event.modifiers = modifiers(bits);
                        self.keys.entry(token).or_insert_with(|| event.clone());
                        out.push(key_message(event));
                    }
                } else if let Some(mut event) = self.keys.remove(&token) {
                    event.down = false;
                    event.modifiers = modifiers(bits);
                    out.push(key_message(event));
                }
            }
            Input::Text { text } => {
                if text.len() > 8192 || text.contains('\0') {
                    bail!("Invalid committed text");
                }
                if !text.is_empty() {
                    let mut event = KeyEvent::new();
                    event.set_seq(text);
                    event.press = true;
                    out.push(key_message(event));
                }
            }
            Input::Pointer {
                x,
                y,
                buttons,
                action,
                modifiers: bits,
            } => {
                if bits & !63 != 0 {
                    bail!("Invalid pointer modifiers");
                }
                self.modifiers = bits;
                let display =
                    display.ok_or_else(|| hbb_common::anyhow::anyhow!("No display selected"))?;
                let inside = i64::from(x) >= i64::from(display.x)
                    && i64::from(y) >= i64::from(display.y)
                    && i64::from(x) < i64::from(display.x) + i64::from(display.width)
                    && i64::from(y) < i64::from(display.y) + i64::from(display.height);
                if !inside {
                    bail!("Pointer is outside the selected display");
                }
                self.position = (x, y);
                let kind = match action {
                    PointerAction::Move => {
                        if buttons != 0 {
                            bail!("Invalid pointer motion mask");
                        }
                        0
                    }
                    PointerAction::Press => {
                        if !matches!(buttons, 1 | 2 | 4 | 8 | 16) {
                            bail!("Invalid pointer button");
                        }
                        self.buttons.insert(buttons);
                        1
                    }
                    PointerAction::Release => {
                        if !self.buttons.remove(&buttons) {
                            return Ok(out);
                        }
                        2
                    }
                };
                out.push(mouse((buttons as i32) << 3 | kind, x, y, self.modifiers));
            }
            Input::Scroll {
                x,
                y,
                precise,
                modifiers: bits,
            } => {
                if bits & !63 != 0 {
                    bail!("Invalid scroll modifiers");
                }
                self.modifiers = bits;
                if !x.is_finite() || !y.is_finite() || x.abs() > 4096. || y.abs() > 4096. {
                    bail!("Invalid scroll delta");
                }
                let scale = if precise { 40. } else { 1. };
                if x.abs() / scale > 100. || y.abs() / scale > 100. {
                    bail!("Scroll delta exceeds event budget");
                }
                self.scroll.0 += x / scale;
                self.scroll.1 += y / scale;
                let dx = self.scroll.0.trunc().clamp(-100., 100.) as i32;
                let dy = self.scroll.1.trunc().clamp(-100., 100.) as i32;
                self.scroll.0 -= f64::from(dx);
                self.scroll.1 -= f64::from(dy);
                if dx != 0 || dy != 0 {
                    out.push(mouse(3, -dx, -dy, self.modifiers));
                }
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base::message_proto::{key_event, message};
    #[test]
    fn release_uses_original_key_and_clears_all_pressed_state() {
        let mut state = State::default();
        state
            .translate(
                Input::Key {
                    keyval: 'A' as u32,
                    hardware_code: 38,
                    pressed: true,
                    modifiers: 1,
                },
                None,
            )
            .unwrap();
        let release = state
            .translate(
                Input::Key {
                    keyval: 'a' as u32,
                    hardware_code: 38,
                    pressed: false,
                    modifiers: 0,
                },
                None,
            )
            .unwrap();
        let Some(message::Union::KeyEvent(event)) = &release[0].union else {
            panic!()
        };
        assert!(!event.down);
        assert!(matches!(event.union, Some(key_event::Union::Chr(65))));
        state
            .translate(
                Input::Key {
                    keyval: 0xffe3,
                    hardware_code: 37,
                    pressed: true,
                    modifiers: 2,
                },
                None,
            )
            .unwrap();
        let display = Display {
            index: 0,
            x: -100,
            y: 20,
            width: 640,
            height: 480,
            name: String::new(),
        };
        state
            .translate(
                Input::Pointer {
                    x: -50,
                    y: 30,
                    buttons: 1,
                    action: PointerAction::Press,
                    modifiers: 0,
                },
                Some(&display),
            )
            .unwrap();
        assert_eq!(state.translate(Input::ReleaseAll, None).unwrap().len(), 2);
        assert!(state.translate(Input::ReleaseAll, None).unwrap().is_empty());
    }
    #[test]
    fn precise_scroll_accumulates_and_invalid_geometry_or_text_is_rejected() {
        let mut state = State::default();
        for _ in 0..3 {
            assert!(state
                .translate(
                    Input::Scroll {
                        x: 0.,
                        y: 10.,
                        precise: true,
                        modifiers: 0
                    },
                    None
                )
                .unwrap()
                .is_empty());
        }
        let events = state
            .translate(
                Input::Scroll {
                    x: 0.,
                    y: 10.,
                    precise: true,
                    modifiers: 0,
                },
                None,
            )
            .unwrap();
        let Some(message::Union::MouseEvent(event)) = &events[0].union else {
            panic!()
        };
        assert_eq!(event.y, -1);
        assert!(state
            .translate(
                Input::Scroll {
                    x: f64::NAN,
                    y: 0.,
                    precise: false,
                    modifiers: 0
                },
                None
            )
            .is_err());
        assert!(state
            .translate(
                Input::Pointer {
                    x: 0,
                    y: 0,
                    buttons: 0,
                    action: PointerAction::Move,
                    modifiers: 0
                },
                None
            )
            .is_err());
        assert!(state
            .translate(
                Input::Text {
                    text: "x".repeat(8193)
                },
                None
            )
            .is_err());
        let events = state
            .translate(
                Input::Text {
                    text: "中文输入".into(),
                },
                None,
            )
            .unwrap();
        assert_eq!(events.len(), 1);
    }
}
