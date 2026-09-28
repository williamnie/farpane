#[no_mangle]
pub unsafe extern "C" fn rdn_host_start(host: *mut RdnHost) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if !matches!(host.state, RdnHostState::Created | RdnHostState::Stopped) {
        return RDN_HOST_ERR_BAD_STATE;
    }
    // Upstream Config/Config2 loading falls back to defaults on malformed or
    // unreadable TOML. The writes below could then replace the last durable
    // identity/config with generated defaults. Inspect both fixed Host files
    // first, without creating or rewriting anything, and fail closed instead.
    if preflight_host_storage().is_err() {
        host.registration_status = "degraded";
        host.state = RdnHostState::Error;
        host.last_error = Some("configuration.storagePreflightFailed".to_owned());
        host.emit_snapshot_changed();
        return RDN_HOST_ERR_STORAGE;
    }
    host.state = RdnHostState::Starting;
    host.emit_snapshot_changed();
    // Install the canonical self-hosted configuration before identity or
    // rendezvous state is touched. The public key is persisted only in the
    // isolated RustDesk host config and never emitted in snapshots/logs.
    config::Config::set_option(
        "custom-rendezvous-server".to_owned(),
        host.rendezvous_server.clone(),
    );
    config::Config::set_option("relay-server".to_owned(), host.relay_server.clone());
    config::Config::set_option("key".to_owned(), host.server_public_key.clone());
    // Clipboard, audio and file transfer are enabled only by their independent
    // create policies. Upstream treats a missing `enable-*` option as enabled,
    // so absence is never accepted as product policy.
    apply_native_host_optional_capability_policy(
        host.clipboard_transfer_policy,
        host.audio_enabled,
        &host.audio_input_device,
        host.file_transfer_enabled,
    );
    // FarPane Host owns an active authenticated screen route as a bounded
    // user-idle sleep assertion. The connection lifecycle releases it when
    // the last remote screen session ends; native mode never forces the
    // physical display to stay lit.
    config::Config::set_option(
        config::keys::OPTION_KEEP_AWAKE_DURING_INCOMING_SESSIONS.to_owned(),
        "Y".to_owned(),
    );
    // First identity access inside the isolated root generates and persists
    // the stable ID/key pair (§9.1).
    host.local_id = config::Config::get_id();
    password_security::update_temporary_password();
    config::Config::set_option("stop-service".to_owned(), String::new());
    // Upstream setters do not propagate confy write failures. Re-open the
    // fixed private files and require the persisted identity/config projection
    // needed by this start before any media or network runtime is created.
    // This proves readback, not fsync durability; the latter remains a
    // separate storage-writer boundary.
    if verify_host_start_storage(host).is_err() {
        host.registration_status = "degraded";
        host.state = RdnHostState::Error;
        host.last_error = Some("configuration.storagePersistenceFailed".to_owned());
        host.emit_snapshot_changed();
        return RDN_HOST_ERR_STORAGE;
    }
    bind_media_host(host);
    // The process-global wakelock worker outlives an individual Host handle.
    // Reset it only after binding this native Host so its thread pins the
    // user-idle (display-off) policy and cannot inherit a prior sleep epoch.
    if !crate::server::native_host_reset_wakelock() {
        unbind_media_host();
        host.registration_status = "degraded";
        host.state = RdnHostState::Error;
        host.recovery_state = HostRecoveryState::Failed;
        host.last_error = Some("power.wakelockResetFailed".to_owned());
        host.emit_snapshot_changed();
        return RDN_HOST_ERR_INTERNAL;
    }
    host.recovery_state = HostRecoveryState::Running;
    // A terminal stop/start begins a fresh product network-observation
    // lifetime. The path trigger owner also restarts from generation zero.
    host.network_path_generation = 0;
    host.runtime = match HostRuntime::start(host.rendezvous_server.clone()) {
        Ok(runtime) => Some(runtime),
        Err(()) => {
            unbind_media_host();
            host.registration_status = "degraded";
            host.state = RdnHostState::Error;
            host.last_error = Some("registration.runtimeStartFailed".to_owned());
            host.emit_snapshot_changed();
            return RDN_HOST_ERR_INTERNAL;
        }
    };
    host.registration_status = "pending";
    host.state = RdnHostState::Starting;
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_stop(host: *mut RdnHost, reason: RdnHostStopReason) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if matches!(host.state, RdnHostState::Stopped | RdnHostState::Stopping) {
        return RDN_HOST_ERR_BAD_STATE;
    }
    host.state = RdnHostState::Stopping;
    unbind_media_host();
    if let Some(mut runtime) = host.runtime.take() {
        if !runtime.stop() {
            host.registration_status = "degraded";
            host.state = RdnHostState::Error;
            host.last_error = Some("registration.runtimeJoinFailed".to_owned());
            host.emit_snapshot_changed();
            return RDN_HOST_ERR_INTERNAL;
        }
    }
    // Invalidate the temporary password on stop (§9.2): rotate so the old
    // value cannot survive a stop/start cycle.
    password_security::update_temporary_password();
    host.reveal_temporary_password = false;
    host.registration_status = "notStarted";
    host.recovery_state = HostRecoveryState::Running;
    if matches!(reason, RdnHostStopReason::Error) {
        host.state = RdnHostState::Error;
    } else {
        host.state = RdnHostState::Stopped;
    }
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

fn fail_host_network_recovery(host: &mut RdnHost, detail: &str) -> i32 {
    host.registration_status = "degraded";
    // Network registration recovery is independent from the exact-epoch
    // sleep/wake state machine. Preserve Running so snapshot consumers do not
    // misclassify a registration failure as a wakelock recovery failure.
    host.recovery_state = HostRecoveryState::Running;
    host.state = RdnHostState::Error;
    host.last_error = Some(detail.to_owned());
    host.emit_snapshot_changed();
    RDN_HOST_ERR_INTERNAL
}

fn is_next_network_path_generation(current: u64, requested: u64) -> bool {
    requested != 0 && current.checked_add(1) == Some(requested)
}

/// Restart only the Rust-owned Rendezvous registration runtime after an
/// authoritative product network-path change. Success means the replacement
/// runtime was started as pending; a later snapshot must prove ready.
#[no_mangle]
pub unsafe extern "C" fn rdn_host_recover_network_path(
    host: *mut RdnHost,
    path_generation: u64,
) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if host.recovery_state != HostRecoveryState::Running
        || !matches!(host.state, RdnHostState::Starting | RdnHostState::Ready)
        || host.runtime.is_none()
    {
        return RDN_HOST_ERR_BAD_STATE;
    }
    if !is_next_network_path_generation(host.network_path_generation, path_generation) {
        return RDN_HOST_ERR_STALE_GENERATION;
    }

    // Commit the exact generation and withdraw the old ready projection before
    // stopping registration. Host identity/configuration and media/session
    // authorities stay bound to this RdnHost lifetime.
    host.network_path_generation = path_generation;
    host.registration_status = "pending";
    host.state = RdnHostState::Starting;
    host.last_error = None;
    host.emit_snapshot_changed();

    let mut runtime = host.runtime.take().unwrap();
    if !runtime.stop() {
        return fail_host_network_recovery(
            host,
            "registration.runtimeJoinFailedDuringNetworkRecovery",
        );
    }
    host.runtime = match HostRuntime::start(host.rendezvous_server.clone()) {
        Ok(runtime) => Some(runtime),
        Err(()) => {
            return fail_host_network_recovery(
                host,
                "registration.runtimeRestartFailedDuringNetworkRecovery",
            );
        }
    };
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

fn fail_host_sleep_recovery(host: &mut RdnHost, detail: &str) -> i32 {
    host.registration_status = "degraded";
    host.recovery_state = HostRecoveryState::Failed;
    host.state = RdnHostState::Error;
    host.last_error = Some(detail.to_owned());
    host.emit_snapshot_changed();
    RDN_HOST_ERR_INTERNAL
}

fn is_next_recovery_epoch(current: u64, requested: u64) -> bool {
    requested != 0 && current.checked_add(1) == Some(requested)
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_begin_sleep(host: *mut RdnHost, epoch: u64) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if host.recovery_state != HostRecoveryState::Running
        || !matches!(host.state, RdnHostState::Starting | RdnHostState::Ready)
        || host.runtime.is_none()
    {
        return RDN_HOST_ERR_BAD_STATE;
    }
    if !is_next_recovery_epoch(host.recovery_epoch, epoch) {
        return RDN_HOST_ERR_STALE_EPOCH;
    }

    host.recovery_epoch = epoch;
    host.recovery_state = HostRecoveryState::Suspending;
    host.registration_status = "suspending";
    host.state = RdnHostState::Starting;
    host.runtime.as_ref().unwrap().request_stop();
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_finish_sleep(host: *mut RdnHost, epoch: u64) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if host.recovery_epoch != epoch {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    if host.recovery_state != HostRecoveryState::Suspending {
        return RDN_HOST_ERR_BAD_STATE;
    }
    let Some(mut runtime) = host.runtime.take() else {
        return fail_host_sleep_recovery(host, "registration.runtimeMissingDuringSleep");
    };
    if !runtime.join() {
        return fail_host_sleep_recovery(host, "registration.runtimeJoinFailedDuringSleep");
    }
    if !crate::server::native_host_suspend_wakelock(epoch) {
        return fail_host_sleep_recovery(host, "power.wakelockSuspendFailed");
    }

    host.registration_status = "suspended";
    host.recovery_state = HostRecoveryState::Suspended;
    host.state = RdnHostState::Starting;
    host.emit_snapshot_changed();
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_resume_after_wake(host: *mut RdnHost, epoch: u64) -> i32 {
    let Some(host) = host.as_mut() else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if host.recovery_epoch != epoch {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    if host.recovery_state != HostRecoveryState::Suspended || host.runtime.is_some() {
        return RDN_HOST_ERR_BAD_STATE;
    }

    host.recovery_state = HostRecoveryState::Resuming;
    host.registration_status = "pending";
    host.state = RdnHostState::Starting;
    if !crate::server::native_host_resume_wakelock(epoch) {
        return fail_host_sleep_recovery(host, "power.wakelockResumeFailed");
    }
    host.runtime = match HostRuntime::start(host.rendezvous_server.clone()) {
        Ok(runtime) => Some(runtime),
        Err(()) => {
            return fail_host_sleep_recovery(host, "registration.runtimeResumeFailed");
        }
    };
    host.emit_snapshot_changed();
    RDN_HOST_OK
}
