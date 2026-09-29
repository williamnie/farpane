#[no_mangle]
pub unsafe extern "C" fn rdn_client_send_clipboard_text(
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
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    if !client.shared.send_clipboard_text.load(Ordering::Acquire) {
        return -7;
    }
    if !client
        .shared
        .remote_clipboard_enabled
        .load(Ordering::Acquire)
    {
        return -8;
    }
    if utf8.is_null() || length == 0 || length > MAX_CLIPBOARD_TEXT_UTF8_BYTES {
        return -4;
    }
    let bytes = std::slice::from_raw_parts(utf8, length);
    let Some(message) = native_viewer_clipboard_message(bytes) else {
        return -4;
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    sender.send(Data::Message(message)).map_or(-3, |_| 0)
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_send_clipboard_rich_text(
    client: *mut RDNClient,
    payload: *const RDNClipboardRichTextPayload,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    if !client
        .shared
        .send_clipboard_rich_text
        .load(Ordering::Acquire)
    {
        return -7;
    }
    if !client
        .shared
        .remote_clipboard_enabled
        .load(Ordering::Acquire)
    {
        return -8;
    }
    let Some(payload) = payload.as_ref() else {
        return -4;
    };
    let Some(message) = (unsafe { native_viewer_clipboard_rich_text_message(payload) }) else {
        return -4;
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    sender.send(Data::Message(message)).map_or(-3, |_| 0)
}

#[no_mangle]
pub unsafe extern "C" fn rdn_client_send_clipboard_image(
    client: *mut RDNClient,
    payload: *const RDNClipboardImagePayload,
) -> i32 {
    let Some(client) = client.as_ref() else {
        return -1;
    };
    if !client.shared.active.load(Ordering::Acquire) {
        return -3;
    }
    if !client.shared.authenticated.load(Ordering::Acquire) {
        return -6;
    }
    if !client.shared.send_clipboard_image.load(Ordering::Acquire) {
        return -7;
    }
    if !client
        .shared
        .remote_clipboard_enabled
        .load(Ordering::Acquire)
    {
        return -8;
    }
    let Some(payload) = payload.as_ref() else {
        return -4;
    };
    let Some(message) = (unsafe { native_viewer_clipboard_image_message(payload) }) else {
        return -4;
    };
    let session = client.session.lock().unwrap().clone();
    let Some(session) = session else {
        return -3;
    };
    let Some(sender) = session.sender.read().unwrap().as_ref().cloned() else {
        return -3;
    };
    sender.send(Data::Message(message)).map_or(-3, |_| 0)
}
