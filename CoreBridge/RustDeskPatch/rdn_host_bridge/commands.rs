fn fail_host_after_password_persistence_mismatch(host: &mut RdnHost) {
    // Config::set_permanent_password cannot report confy's write error. Once
    // readback proves that the in-memory verifier/salt is not durable, stop
    // every active route before reporting the terminal storage state. This
    // prevents a running Host from authenticating against ephemeral state.
    unbind_media_host();
    if let Some(mut runtime) = host.runtime.take() {
        let _ = runtime.stop();
    }
    password_security::update_temporary_password();
    host.reveal_temporary_password = false;
    host.registration_status = "degraded";
    host.state = RdnHostState::Error;
    host.last_error = Some("configuration.passwordPersistenceFailed".to_owned());
    host.emit_snapshot_changed();
}

fn parse_envelope(bytes: &[u8]) -> Result<Value, i32> {
    if bytes.is_empty() || bytes.len() > MAX_ENVELOPE_BYTES {
        return Err(RDN_HOST_ERR_VALIDATION);
    }
    serde_json::from_slice(bytes).map_err(|_| RDN_HOST_ERR_VALIDATION)
}

fn approval_connection_id(envelope: &Value) -> Result<&str, i32> {
    let Some(object) = envelope.as_object() else {
        return Err(RDN_HOST_ERR_VALIDATION);
    };
    if object.len() != 3
        || !object.contains_key("commandId")
        || !object.contains_key("name")
        || !object.contains_key("connectionId")
    {
        return Err(RDN_HOST_ERR_VALIDATION);
    }
    match object.get("connectionId").and_then(Value::as_str) {
        Some(value)
            if !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control) =>
        {
            Ok(value)
        }
        _ => Err(RDN_HOST_ERR_VALIDATION),
    }
}

fn session_connection_id(envelope: &Value) -> Result<&str, i32> {
    let Some(object) = envelope.as_object() else {
        return Err(RDN_HOST_ERR_VALIDATION);
    };
    if object.len() != 3
        || !object.contains_key("commandId")
        || !object.contains_key("name")
        || !object.contains_key("connectionId")
    {
        return Err(RDN_HOST_ERR_VALIDATION);
    }
    match object.get("connectionId").and_then(Value::as_str) {
        Some(value)
            if !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control) =>
        {
            Ok(value)
        }
        _ => Err(RDN_HOST_ERR_VALIDATION),
    }
}

fn handle_approval_command(
    host: &mut RdnHost,
    command_id: &str,
    decision: NativeApprovalDecision,
    envelope: &Value,
) -> i32 {
    let connection_id = match approval_connection_id(envelope) {
        Ok(value) => value,
        Err(code) => {
            host.emit_command_result(command_id, "rejected", "approval-command-invalid");
            return code;
        }
    };
    let expected_prefix = format!("{}:", host.instance_id);
    if !connection_id.starts_with(&expected_prefix) {
        host.emit_command_result(command_id, "rejected", "approval-not-found");
        return RDN_HOST_ERR_APPROVAL_NOT_FOUND;
    }
    match native_host_resolve_approval(connection_id, decision) {
        NativeApprovalResolveResult::Approved => {
            host.emit_command_result(command_id, "ok", "approval-approved");
            RDN_HOST_OK
        }
        NativeApprovalResolveResult::Rejected => {
            host.emit_command_result(command_id, "ok", "approval-rejected");
            RDN_HOST_OK
        }
        NativeApprovalResolveResult::Expired => {
            host.emit_command_result(command_id, "rejected", "approval-expired");
            RDN_HOST_ERR_APPROVAL_EXPIRED
        }
        NativeApprovalResolveResult::AlreadyFinal => {
            host.emit_command_result(command_id, "rejected", "approval-already-finalized");
            RDN_HOST_ERR_APPROVAL_FINALIZED
        }
        NativeApprovalResolveResult::NotFound => {
            host.emit_command_result(command_id, "rejected", "approval-not-found");
            RDN_HOST_ERR_APPROVAL_NOT_FOUND
        }
    }
}

fn handle_session_command(
    host: &mut RdnHost,
    command_id: &str,
    command: NativeSessionCommand,
    envelope: &Value,
) -> i32 {
    let connection_id = match session_connection_id(envelope) {
        Ok(value) => value,
        Err(code) => {
            host.emit_command_result(command_id, "rejected", "session-command-invalid");
            return code;
        }
    };
    let expected_prefix = format!("{}:", host.instance_id);
    if !connection_id.starts_with(&expected_prefix) {
        host.emit_command_result(command_id, "rejected", "session-not-found");
        return RDN_HOST_ERR_SESSION_NOT_FOUND;
    }

    match SESSION_BROKER
        .lock()
        .unwrap()
        .command(connection_id, command)
    {
        NativeSessionCommandResult::Queued => {
            let detail = match command {
                NativeSessionCommand::DisableInput => "session-input-disable-queued",
                NativeSessionCommand::DisableClipboardRead => {
                    "session-clipboard-read-disable-queued"
                }
                NativeSessionCommand::DisableClipboardWrite => {
                    "session-clipboard-write-disable-queued"
                }
                NativeSessionCommand::DisableClipboard => "session-clipboard-disable-queued",
                NativeSessionCommand::DisableAudio => "session-audio-disable-queued",
                NativeSessionCommand::Disconnect => "session-disconnect-queued",
            };
            host.emit_command_result(command_id, "ok", detail);
            RDN_HOST_OK
        }
        NativeSessionCommandResult::NoChange => {
            let detail = match command {
                NativeSessionCommand::DisableInput => "session-input-already-disabled",
                NativeSessionCommand::DisableClipboardRead => {
                    "session-clipboard-read-already-disabled"
                }
                NativeSessionCommand::DisableClipboardWrite => {
                    "session-clipboard-write-already-disabled"
                }
                NativeSessionCommand::DisableClipboard => "session-clipboard-already-disabled",
                NativeSessionCommand::DisableAudio => "session-audio-already-disabled",
                NativeSessionCommand::Disconnect => "session-disconnect-already-requested",
            };
            host.emit_command_result(command_id, "ok", detail);
            RDN_HOST_OK
        }
        NativeSessionCommandResult::NotFound => {
            host.emit_command_result(command_id, "rejected", "session-not-found");
            RDN_HOST_ERR_SESSION_NOT_FOUND
        }
        NativeSessionCommandResult::Stale => {
            host.emit_command_result(command_id, "rejected", "session-stale");
            RDN_HOST_ERR_SESSION_STALE
        }
        NativeSessionCommandResult::Unavailable => {
            host.emit_command_result(command_id, "error", "session-command-unavailable");
            RDN_HOST_ERR_SESSION_COMMAND_UNAVAILABLE
        }
    }
}

fn handle_command(host: &mut RdnHost, command_id: &str, name: &str, envelope: &Value) -> i32 {
    match name {
        "enableHost" => {
            // Host already runs in-process for the H1a spike; accept as no-op.
            host.emit_command_result(command_id, "ok", "host-enabled");
            RDN_HOST_OK
        }
        "disableHost" => {
            host.emit_command_result(command_id, "ok", "host-disabled");
            RDN_HOST_OK
        }
        "regenerateTemporaryPassword" => {
            password_security::update_temporary_password();
            host.emit_command_result(command_id, "ok", "temporary-password-regenerated");
            host.emit_snapshot_changed();
            RDN_HOST_OK
        }
        "revealTemporaryPassword" => {
            host.reveal_temporary_password = true;
            host.emit_command_result(command_id, "ok", "temporary-password-revealed");
            RDN_HOST_OK
        }
        "clearPermanentPassword" => {
            if config::Config::is_disable_change_permanent_password() {
                host.emit_command_result(
                    command_id,
                    "rejected",
                    "permanent-password-change-disabled",
                );
                RDN_HOST_ERR_CHANGE_DISABLED
            } else if config::Config::set_permanent_password("") {
                if verify_host_password_storage().is_err() {
                    host.emit_command_result(
                        command_id,
                        "error",
                        "permanent-password-storage-failed",
                    );
                    fail_host_after_password_persistence_mismatch(host);
                    return RDN_HOST_ERR_STORAGE;
                }
                let detail = if config::Config::has_permanent_password() {
                    "permanent-password-local-cleared-preset-still-effective"
                } else {
                    "permanent-password-local-cleared"
                };
                host.emit_command_result(command_id, "ok", detail);
                host.emit_snapshot_changed();
                RDN_HOST_OK
            } else {
                host.emit_command_result(command_id, "error", "permanent-password-storage-failed");
                RDN_HOST_ERR_STORAGE
            }
        }
        "approveConnection" => {
            handle_approval_command(host, command_id, NativeApprovalDecision::Approve, envelope)
        }
        "rejectConnection" => {
            handle_approval_command(host, command_id, NativeApprovalDecision::Reject, envelope)
        }
        "disableInputForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableInput,
            envelope,
        ),
        "disableClipboardForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableClipboard,
            envelope,
        ),
        "disableClipboardReadForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableClipboardRead,
            envelope,
        ),
        "disableClipboardWriteForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableClipboardWrite,
            envelope,
        ),
        "disableAudioForActiveSession" => handle_session_command(
            host,
            command_id,
            NativeSessionCommand::DisableAudio,
            envelope,
        ),
        "disconnectSession" => {
            handle_session_command(host, command_id, NativeSessionCommand::Disconnect, envelope)
        }
        _ => {
            host.emit_command_result(command_id, "unknownCommand", name);
            RDN_HOST_OK
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_command(
    host: *mut RdnHost,
    command_json: *const u8,
    length: usize,
) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if command_json.is_null() {
        return RDN_HOST_ERR_INVALID_ARG;
    }
    let bytes = std::slice::from_raw_parts(command_json, length);
    let envelope = match parse_envelope(bytes) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let command_id = match envelope.get("commandId").and_then(Value::as_str) {
        Some(value) if !value.is_empty() && value.len() <= 128 => value.to_owned(),
        _ => return RDN_HOST_ERR_VALIDATION,
    };
    let name = match envelope.get("name").and_then(Value::as_str) {
        Some(value)
            if !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control) =>
        {
            value.to_owned()
        }
        _ => return RDN_HOST_ERR_VALIDATION,
    };
    handle_command(host, &command_id, &name, &envelope)
}

/// Dedicated permanent-password ingress (§9.3). Password bytes never enter
/// JSON, logging, command-line arguments or persistent Swift storage. Rust
/// borrows the caller-owned mutable buffer and SecretBuffer wipes it on every
/// path after pointer validation; the Swift wrapper performs a second wipe.
#[no_mangle]
pub unsafe extern "C" fn rdn_host_set_permanent_password(
    host: *mut RdnHost,
    command_id: *const c_char,
    password_utf8: *mut u8,
    password_length: usize,
) -> i32 {
    if password_utf8.is_null() && password_length != 0 {
        return RDN_HOST_ERR_INVALID_ARG;
    }
    let secret = if password_utf8.is_null() {
        None
    } else {
        Some(SecretBuffer::from_raw_parts(password_utf8, password_length))
    };
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    let command_id = match required_string(command_id) {
        Ok(value)
            if !value.is_empty() && value.len() <= 128 && !value.chars().any(char::is_control) =>
        {
            value
        }
        Ok(_) => return RDN_HOST_ERR_VALIDATION,
        Err(code) => return code,
    };
    let bytes = secret.as_ref().map(SecretBuffer::bytes).unwrap_or_default();
    let password = match validate_permanent_password(bytes) {
        Ok(password) => password,
        Err(rejection) => {
            host.emit_command_result(&command_id, "rejected", rejection.detail);
            return rejection.code;
        }
    };
    if config::Config::is_disable_change_permanent_password() {
        host.emit_command_result(
            &command_id,
            "rejected",
            "permanent-password-change-disabled",
        );
        return RDN_HOST_ERR_CHANGE_DISABLED;
    }
    if !config::Config::set_permanent_password(password) {
        host.emit_command_result(&command_id, "error", "permanent-password-storage-failed");
        return RDN_HOST_ERR_STORAGE;
    }
    if verify_host_password_storage().is_err() {
        host.emit_command_result(&command_id, "error", "permanent-password-storage-failed");
        fail_host_after_password_persistence_mismatch(host);
        return RDN_HOST_ERR_STORAGE;
    }
    host.emit_command_result(&command_id, "ok", "permanent-password-set");
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_copy_snapshot(
    host: *mut RdnHost,
    out_snapshot: *mut RdnHostOwnedBytes,
) -> i32 {
    let (Some(host), Some(out_snapshot)) = (host.as_mut(), out_snapshot.as_mut()) else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    let encoded = match serde_json::to_vec(&host.snapshot_json()) {
        Ok(value) => value,
        Err(_) => return RDN_HOST_ERR_INTERNAL,
    };
    let mut boxed = encoded.into_boxed_slice();
    out_snapshot.data = boxed.as_mut_ptr();
    out_snapshot.length = boxed.len();
    out_snapshot.capacity = boxed.len();
    std::mem::forget(boxed);
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_free_bytes(bytes: RdnHostOwnedBytes) {
    if bytes.data.is_null() || bytes.capacity == 0 {
        return;
    }
    drop(Box::from_raw(std::slice::from_raw_parts_mut(
        bytes.data,
        bytes.capacity,
    )));
}
