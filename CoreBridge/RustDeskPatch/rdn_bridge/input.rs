fn pointer_mask(kind: RDNPointerKind, buttons: u32) -> Option<i32> {
    if buttons & !VALID_POINTER_BUTTONS != 0 {
        return None;
    }
    let event_type = match kind {
        RDNPointerKind::Move => MOUSE_TYPE_MOVE,
        RDNPointerKind::Down => MOUSE_TYPE_DOWN,
        RDNPointerKind::Up => MOUSE_TYPE_UP,
        RDNPointerKind::Scroll => MOUSE_TYPE_WHEEL,
        RDNPointerKind::PreciseScroll => MOUSE_TYPE_TRACKPAD,
    };
    let mut upstream_buttons = 0;
    if buttons & POINTER_BUTTON_LEFT != 0 {
        upstream_buttons |= MOUSE_BUTTON_LEFT;
    }
    if buttons & POINTER_BUTTON_RIGHT != 0 {
        upstream_buttons |= MOUSE_BUTTON_RIGHT;
    }
    if buttons & POINTER_BUTTON_MIDDLE != 0 {
        upstream_buttons |= MOUSE_BUTTON_WHEEL;
    }
    match kind {
        RDNPointerKind::Down | RDNPointerKind::Up if upstream_buttons.count_ones() != 1 => {
            return None;
        }
        RDNPointerKind::Scroll | RDNPointerKind::PreciseScroll if upstream_buttons != 0 => {
            return None;
        }
        _ => {}
    }
    Some(event_type | (upstream_buttons << 3))
}

fn pointer_payload_fields_are_canonical(
    kind: RDNPointerKind,
    x: i32,
    y: i32,
    scroll_x: i32,
    scroll_y: i32,
) -> bool {
    if matches!(kind, RDNPointerKind::Scroll | RDNPointerKind::PreciseScroll) {
        x == 0 && y == 0
    } else {
        scroll_x == 0 && scroll_y == 0
    }
}

fn key_name(code: RDNKeyCode, unicode_scalar: u32) -> Option<String> {
    let special = match code {
        RDNKeyCode::Character => {
            return char::from_u32(unicode_scalar)
                .filter(|value| *value != '\0')
                .map(|value| value.to_string())
        }
        RDNKeyCode::Escape => "VK_ESCAPE",
        RDNKeyCode::Return => "VK_RETURN",
        RDNKeyCode::Tab => "VK_TAB",
        RDNKeyCode::Backspace => "VK_BACK",
        RDNKeyCode::DeleteForward => "VK_DELETE",
        RDNKeyCode::Left => "VK_LEFT",
        RDNKeyCode::Right => "VK_RIGHT",
        RDNKeyCode::Up => "VK_UP",
        RDNKeyCode::Down => "VK_DOWN",
        RDNKeyCode::Space => "VK_SPACE",
        RDNKeyCode::Shift => "VK_SHIFT",
        RDNKeyCode::Control => "VK_CONTROL",
        RDNKeyCode::Option => "VK_MENU",
        RDNKeyCode::Command => "Meta",
        RDNKeyCode::Home => "VK_HOME",
        RDNKeyCode::End => "VK_END",
        RDNKeyCode::PageUp => "VK_PRIOR",
        RDNKeyCode::PageDown => "VK_NEXT",
        RDNKeyCode::Physical => return None,
    };
    Some(special.to_owned())
}

fn key_payload_fields_are_canonical(
    code: RDNKeyCode,
    unicode_scalar: u32,
    hardware_keycode: u32,
) -> bool {
    match code {
        RDNKeyCode::Character => hardware_keycode == 0,
        RDNKeyCode::Physical => unicode_scalar == 0,
        _ => unicode_scalar == 0 && hardware_keycode == 0,
    }
}

fn physical_macos_keycode(value: u32) -> Option<i32> {
    // macOS virtual hardware key positions are 7-bit values. Keeping this
    // validation in Rust prevents Swift from exposing RustDesk wire details.
    (value <= 0x7f).then_some(value as i32)
}

fn modifiers(value: u32) -> Option<(bool, bool, bool, bool)> {
    if value & !VALID_MODIFIERS != 0 {
        return None;
    }
    Some((
        value & MODIFIER_OPTION != 0,
        value & MODIFIER_CONTROL != 0,
        value & MODIFIER_SHIFT != 0,
        value & MODIFIER_COMMAND != 0,
    ))
}

fn clamp_pointer_coordinates(x: i32, y: i32, dimensions: (u32, u32)) -> Option<(i32, i32)> {
    let maximum_x = dimensions.0.checked_sub(1)?.min(i32::MAX as u32) as i32;
    let maximum_y = dimensions.1.checked_sub(1)?.min(i32::MAX as u32) as i32;
    Some((x.clamp(0, maximum_x), y.clamp(0, maximum_y)))
}

fn normalized_pointer_coordinates(
    kind: RDNPointerKind,
    x: i32,
    y: i32,
    scroll_x: i32,
    scroll_y: i32,
    dimensions: (u32, u32),
) -> Option<(i32, i32)> {
    if matches!(kind, RDNPointerKind::Scroll | RDNPointerKind::PreciseScroll) {
        let point = (scroll_x.clamp(-120, 120), scroll_y.clamp(-120, 120));
        return (point != (0, 0)).then_some(point);
    }
    clamp_pointer_coordinates(x, y, dimensions)
}

fn validated_text(bytes: &[u8]) -> Option<&str> {
    if bytes.is_empty() || bytes.len() > MAX_TEXT_BYTES {
        return None;
    }
    std::str::from_utf8(bytes)
        .ok()
        .filter(|text| !text.contains('\0'))
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_send_pointer(
    client: *mut RDNClient,
    event: *const RDNPointerEvent,
) -> i32 {
    let (Some(client), Some(event)) = (client.as_ref(), event.as_ref()) else {
        return -1;
    };
    if event.abi_version != ABI_VERSION {
        return -2;
    }
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.input_allowed.load(Ordering::Acquire) {
        return -6;
    }
    if !pointer_payload_fields_are_canonical(
        event.kind,
        event.x,
        event.y,
        event.scroll_x,
        event.scroll_y,
    ) {
        return -4;
    }
    let Some(mask) = pointer_mask(event.kind, event.buttons) else {
        return -4;
    };
    let Some((alt, ctrl, shift, command)) = modifiers(event.modifiers) else {
        return -4;
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    let dimensions = *client.shared.dimensions.read().unwrap();
    let Some((x, y)) = normalized_pointer_coordinates(
        event.kind,
        event.x,
        event.y,
        event.scroll_x,
        event.scroll_y,
        dimensions,
    ) else {
        return -5;
    };
    session.send_mouse(mask, x, y, alt, ctrl, shift, command);
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_send_key(
    client: *mut RDNClient,
    event: *const RDNKeyEvent,
) -> i32 {
    let (Some(client), Some(event)) = (client.as_ref(), event.as_ref()) else {
        return -1;
    };
    if event.abi_version != ABI_VERSION {
        return -2;
    }
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.input_allowed.load(Ordering::Acquire) {
        return -6;
    }
    if !key_payload_fields_are_canonical(event.code, event.unicode_scalar, event.hardware_keycode) {
        return -4;
    }
    let physical_keycode = if event.code == RDNKeyCode::Physical {
        let Some(keycode) = physical_macos_keycode(event.hardware_keycode) else {
            return -4;
        };
        Some(keycode)
    } else {
        None
    };
    let name = if physical_keycode.is_none() {
        let Some(name) = key_name(event.code, event.unicode_scalar) else {
            return -4;
        };
        Some(name)
    } else {
        None
    };
    let Some((alt, ctrl, shift, command)) = modifiers(event.modifiers) else {
        return -4;
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    if let Some(keycode) = physical_keycode {
        session.handle_flutter_raw_key_event("map", "", keycode, keycode, 0, event.down);
        return 0;
    }
    session.input_key(
        name.as_deref().expect("semantic key name was validated"),
        event.down,
        false,
        alt,
        ctrl,
        shift,
        command,
    );
    0
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_send_text(
    client: *mut RDNClient,
    utf8: *const u8,
    length: usize,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.input_allowed.load(Ordering::Acquire) {
        return -6;
    }
    if utf8.is_null() || length == 0 || length > MAX_TEXT_BYTES {
        return -4;
    }
    let bytes = std::slice::from_raw_parts(utf8, length);
    let Some(text) = validated_text(bytes) else {
        return -4;
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    session.input_string(text);
    0
}
