fn now_unix_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(u64::MAX as u128) as u64)
        .unwrap_or(0)
}

/// CSPRNG hex token for the host instance identity (not a secret credential).
fn random_instance_id() -> String {
    let mut bytes = [0u8; 8];
    if let Ok(mut file) = std::fs::File::open("/dev/urandom") {
        use std::io::Read;
        if file.read_exact(&mut bytes).is_err() {
            bytes = now_unix_millis().to_ne_bytes();
        }
    } else {
        bytes = now_unix_millis().to_ne_bytes();
    }
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

unsafe fn required_string(pointer: *const c_char) -> Result<String, i32> {
    if pointer.is_null() {
        return Err(RDN_HOST_ERR_INVALID_ARG);
    }
    CStr::from_ptr(pointer)
        .to_str()
        .map(str::to_owned)
        .map_err(|_| RDN_HOST_ERR_VALIDATION)
}

unsafe fn optional_string(pointer: *const c_char) -> Result<String, i32> {
    if pointer.is_null() {
        return Ok(String::new());
    }
    CStr::from_ptr(pointer)
        .to_str()
        .map(str::to_owned)
        .map_err(|_| RDN_HOST_ERR_VALIDATION)
}

fn valid_server(value: &str, allow_empty: bool) -> bool {
    (allow_empty || !value.is_empty())
        && value.len() <= MAX_SERVER_BYTES
        && !value.chars().any(|character| {
            character.is_control()
                || character.is_whitespace()
                || matches!(character, '@' | '?' | '#' | '&')
        })
}

fn valid_server_public_key(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_SERVER_PUBLIC_KEY_BYTES
        && crate::decode64(value)
            .map(|decoded| decoded.len() == 32)
            .unwrap_or(false)
}

fn valid_namespace_component(value: &str) -> bool {
    // APP_NAME/ORG flow into directory names, toml names and the IPC socket
    // path; keep them conservative so isolation cannot escape the sandbox.
    !value.is_empty()
        && value.len() <= MAX_NAME_BYTES
        && !value.contains(|component| matches!(component, '/' | '\\' | ':' | '\0'))
        && value != "."
        && value != ".."
}

#[no_mangle]
pub extern "C" fn rdn_host_abi_version() -> u32 {
    HOST_ABI_VERSION
}

#[no_mangle]
pub extern "C" fn rdn_host_upstream_commit() -> *const c_char {
    UPSTREAM_COMMIT.as_ptr() as *const c_char
}

/// Early config-root entry (host-mode-h0.md §2.3 conclusion 2): must be the
/// first host ABI call in the process, before any hbb_common Config access,
/// and runs exactly once. Switching APP_NAME/ORG moves the config directory,
/// toml file names, log directory and IPC socket (§3.5 of the H0 report).
#[no_mangle]
pub unsafe extern "C" fn rdn_host_set_config_root(
    app_name: *const c_char,
    org: *const c_char,
) -> i32 {
    if CONFIG_ROOT_SET.load(Ordering::Acquire) || HOST_INSTANCE_LIVE.load(Ordering::Acquire) {
        return RDN_HOST_ERR_BAD_STATE;
    }
    let app_name = match required_string(app_name) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let org = match required_string(org) {
        Ok(value) => value,
        Err(code) => return code,
    };
    if !valid_namespace_component(&app_name) || !valid_namespace_component(&org) {
        return RDN_HOST_ERR_VALIDATION;
    }
    *config::APP_NAME.write().unwrap() = app_name;
    #[cfg(target_os = "macos")]
    {
        *config::ORG.write().unwrap() = org;
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = org;
    }
    CONFIG_ROOT_SET.store(true, Ordering::Release);
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_create(
    options: *const RdnHostCreateOptions,
    callbacks: *const RdnHostCallbacks,
    out_host: *mut *mut RdnHost,
) -> i32 {
    if options.is_null() || callbacks.is_null() || out_host.is_null() {
        return RDN_HOST_ERR_INVALID_ARG;
    }
    if (*options).abi_version != HOST_ABI_VERSION || (*callbacks).abi_version != HOST_ABI_VERSION {
        return RDN_HOST_ERR_ABI_MISMATCH;
    }
    if !CONFIG_ROOT_SET.load(Ordering::Acquire) {
        // Fail closed: creating a host before the config-root switch would
        // touch the shared RustDesk config namespace (§18 rule 6).
        return RDN_HOST_ERR_BAD_STATE;
    }
    let rendezvous_server = match required_string((*options).rendezvous_server) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let relay_server = match optional_string((*options).relay_server) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let server_public_key = match required_string((*options).server_public_key) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let audio_input_device = match optional_string((*options).audio_input_device) {
        Ok(value) => value,
        Err(code) => return code,
    };
    let file_transfer_receive_root = match optional_string((*options).file_transfer_receive_root) {
        Ok(value) => value,
        Err(code) => return code,
    };
    if !valid_server(&rendezvous_server, false)
        || !valid_server(&relay_server, true)
        || !valid_server_public_key(&server_public_key)
        || !valid_native_host_audio_input_device(
            (*options).enable_audio,
            &audio_input_device,
        )
        || (*options).enable_file_transfer != !file_transfer_receive_root.is_empty()
    {
        return RDN_HOST_ERR_VALIDATION;
    }
    if HOST_INSTANCE_LIVE
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return RDN_HOST_ERR_BAD_STATE;
    }
    #[cfg(target_os = "macos")]
    let file_service_owner =
        match rdn_host_file_transfer::NativeHostFileServiceOwner::from_immutable_configuration(
            (*options).enable_file_transfer,
            (!file_transfer_receive_root.is_empty())
                .then(|| std::path::Path::new(&file_transfer_receive_root)),
        ) {
            Ok(owner) => owner.map(Arc::new),
            Err(error) => {
                HOST_INSTANCE_LIVE.store(false, Ordering::Release);
                let code = if error
                    == rdn_host_file_transfer::NativeFileTransferRootError::InvalidOwnerConfiguration
                {
                    RDN_HOST_ERR_VALIDATION
                } else {
                    RDN_HOST_ERR_STORAGE
                };
                return code;
            }
        };
    #[cfg(not(target_os = "macos"))]
    if (*options).enable_file_transfer {
        HOST_INSTANCE_LIVE.store(false, Ordering::Release);
        return RDN_HOST_ERR_NOT_SUPPORTED;
    }
    let host = Box::new(RdnHost {
        instance_id: random_instance_id(),
        state: RdnHostState::Created,
        local_id: String::new(),
        registration_status: "notStarted",
        recovery_epoch: 0,
        recovery_state: HostRecoveryState::Running,
        network_path_generation: 0,
        reveal_temporary_password: false,
        last_error: None,
        event_id: Arc::new(AtomicU64::new(0)),
        callbacks: *callbacks,
        rendezvous_server,
        relay_server,
        server_public_key,
        clipboard_transfer_policy: NativeClipboardTransferPolicy::with_image_policy(
            NativeClipboardPolicy::new(
                (*options).enable_clipboard_read,
                (*options).enable_clipboard_write,
            ),
            NativeClipboardPolicy::new(
                (*options).enable_clipboard_rich_text_read,
                (*options).enable_clipboard_rich_text_write,
            ),
            NativeClipboardPolicy::new(
                (*options).enable_clipboard_image_read,
                (*options).enable_clipboard_image_write,
            ),
        ),
        audio_enabled: (*options).enable_audio,
        audio_input_device,
        file_transfer_enabled: (*options).enable_file_transfer,
        #[cfg(target_os = "macos")]
        file_service_owner,
        runtime: None,
    });
    *out_host = Box::into_raw(host);
    RDN_HOST_OK
}
