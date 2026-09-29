pub(crate) fn native_host_begin_session(
    core_connection_id: i32,
    remote_id: String,
    remote_name: String,
    remote_platform: String,
    initial_capabilities: NativeSessionCapabilities,
    active_capabilities: NativeSessionCapabilities,
    input_availability: NativeSessionInputAvailability,
    command_sender: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
) -> bool {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    let Some(binding) = binding else {
        return false;
    };
    let snapshot = NativeSessionSnapshot {
        connection_id: format!("{}:{core_connection_id}", binding.instance_id),
        core_connection_id,
        remote_id: bounded_remote_metadata(remote_id),
        remote_name: bounded_remote_metadata(remote_name),
        remote_platform: bounded_remote_metadata(remote_platform),
        started_at_ms: now_unix_millis(),
        initial_capabilities,
        active_capabilities,
        input_availability,
    };
    let result = SESSION_BROKER.lock().unwrap().begin(NativeActiveSession {
        snapshot: snapshot.clone(),
        command_sender,
        disconnect_requested: false,
    });
    match result {
        NativeSessionStartResult::Accepted => {
            emit_bound_event(&binding, "sessionStarted", snapshot.event_payload());
            emit_bound_event(&binding, "snapshotChanged", json!({}));
            true
        }
        NativeSessionStartResult::Existing => true,
        NativeSessionStartResult::Busy | NativeSessionStartResult::Invalid => false,
    }
}

pub(crate) fn native_host_update_session_capabilities(
    core_connection_id: i32,
    active_capabilities: NativeSessionCapabilities,
    input_availability: NativeSessionInputAvailability,
) {
    let snapshot = SESSION_BROKER.lock().unwrap().update_capabilities(
        core_connection_id,
        active_capabilities,
        input_availability,
    );
    let Some(snapshot) = snapshot else { return };
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "sessionCapabilitiesChanged",
            json!({
                "connectionId": snapshot.connection_id,
                "activeCapabilities": snapshot.active_capabilities.names(),
                "inputAvailability": snapshot.input_availability.name(),
                "inputUnavailableReason": snapshot.input_availability.reason(),
            }),
        );
        emit_bound_event(&binding, "snapshotChanged", json!({}));
    }
}

pub(crate) fn native_host_end_session(core_connection_id: i32) {
    let ended = SESSION_BROKER.lock().unwrap().end(core_connection_id);
    let Some(ended) = ended else { return };
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "sessionEnded",
            json!({
                "connectionId": ended.snapshot.connection_id,
                "reason": "connectionClosed",
            }),
        );
        emit_bound_event(&binding, "snapshotChanged", json!({}));
    }
}

fn native_host_pending_approval_snapshot(host_instance_id: &str) -> Option<Value> {
    let (request, completion) = APPROVAL_BROKER.lock().unwrap().snapshot(Instant::now());
    if let Some(completion) = completion {
        emit_native_approval_completion(&completion);
    }
    let request = request?;
    let expected_prefix = format!("{host_instance_id}:");
    request
        .connection_id
        .starts_with(&expected_prefix)
        .then(|| request.event_payload())
}

fn native_host_active_session_snapshot(host_instance_id: &str) -> Option<Value> {
    let snapshot = SESSION_BROKER.lock().unwrap().snapshot()?;
    let expected_prefix = format!("{host_instance_id}:");
    snapshot
        .connection_id
        .starts_with(&expected_prefix)
        .then(|| snapshot.event_payload())
}

fn reset_native_approval_broker() {
    let pending = APPROVAL_BROKER.lock().unwrap().reset();
    if let Some(pending) = pending {
        let _ = pending.decision_sender.send(crate::ipc::Data::Close);
    }
}

fn reset_native_session_broker(reason: &str) {
    let active = SESSION_BROKER.lock().unwrap().reset();
    let Some(active) = active else { return };
    let _ = active.command_sender.send(crate::ipc::Data::Close);
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "sessionEnded",
            json!({
                "connectionId": active.snapshot.connection_id,
                "reason": reason,
            }),
        );
        emit_bound_event(&binding, "snapshotChanged", json!({}));
    }
}

fn bind_media_host(host: &RdnHost) {
    reset_native_approval_broker();
    reset_native_session_broker("hostRebound");
    // Native Host capture needs Retina enabled so the display catalog and
    // capture contract use physical pixels. The patched Quartz display layer
    // reads the current CGDisplayMode pixel size instead of blindly
    // multiplying the logical size by the backing scale, which keeps both
    // 2048x1152@2x and scaled external-display modes truthful.
    #[cfg(target_os = "macos")]
    {
        *scrap::quartz::ENABLE_RETINA.lock().unwrap() = true;
    }
    let mut broker = MEDIA_BROKER.lock().unwrap();
    broker.routes.clear();
    broker.display_revisions.clear();
    broker.pending_display_reconfigures.clear();
    broker.capabilities = MediaCapabilities::default();
    broker.clipboard_transfer_policy = host.clipboard_transfer_policy;
    #[cfg(target_os = "macos")]
    {
        broker.file_service_owner = host.file_service_owner.clone();
    }
    broker.binding = Some(MediaHostBinding {
        instance_id: host.instance_id.clone(),
        callback: host.callbacks.on_event,
        context: host.callbacks.context as usize,
        event_id: host.event_id.clone(),
    });
    scrap::codec::set_native_encoding_capabilities(false, false);
}

/// The native FarPane Host owns connection status inside the main App and has
/// no separate RustDesk connection-manager process. Server connections use
/// this signal to avoid spawning the current executable with `--cm`.
pub(crate) fn native_host_is_bound() -> bool {
    MEDIA_BROKER.lock().unwrap().binding.is_some()
}

/// Process-lifetime connection-manager ownership is established by the
/// successful config-root-first Host entry and never falls back during
/// start failure, media unbind, stop-drain, destroy, or a later Host restart.
pub(crate) fn native_host_owns_connection_manager() -> bool {
    CONFIG_ROOT_SET.load(Ordering::Acquire)
}

/// Stable for the full native Host instance lifetime, including the interval
/// where stop has unbound media but server connections are still draining.
pub(crate) fn native_host_instance_is_live() -> bool {
    HOST_INSTANCE_LIVE.load(Ordering::Acquire)
}

fn unbind_media_host() {
    reset_native_approval_broker();
    reset_native_session_broker("hostStopped");
    let (binding, routes) = {
        let mut broker = MEDIA_BROKER.lock().unwrap();
        let binding = broker.binding.take();
        let routes = broker
            .routes
            .drain()
            .map(|(display, route)| {
                (
                    display,
                    route.connection_epoch,
                    route.codec_epoch,
                    route.display_revision,
                    route.queue_telemetry.snapshot(),
                    route.writer_telemetry.snapshot(),
                    route.network_telemetry.snapshot(),
                    route.transport_telemetry.snapshot(),
                )
            })
            .collect::<Vec<_>>();
        broker.display_revisions.clear();
        broker.pending_display_reconfigures.clear();
        broker.capabilities = MediaCapabilities::default();
        broker.clipboard_transfer_policy = NativeClipboardTransferPolicy::default();
        #[cfg(target_os = "macos")]
        {
            broker.file_service_owner = None;
        }
        (binding, routes)
    };
    scrap::codec::set_native_encoding_capabilities(false, false);
    if let Some(binding) = binding {
        for (
            display_id,
            connection_epoch,
            codec_epoch,
            display_revision,
            queue,
            writer,
            network,
            transport,
        ) in routes
        {
            emit_bound_event(
                &binding,
                "mediaQueueDiagnostic",
                native_media_queue_payload(
                    "routeStopped",
                    connection_epoch,
                    codec_epoch,
                    display_id,
                    display_revision,
                    queue,
                ),
            );
            emit_bound_event(
                &binding,
                "mediaWriterDiagnostic",
                native_media_writer_payload(
                    "routeStopped",
                    connection_epoch,
                    codec_epoch,
                    display_id,
                    display_revision,
                    writer,
                ),
            );
            emit_bound_event(
                &binding,
                "mediaNetworkDiagnostic",
                native_media_network_payload(
                    "routeStopped",
                    connection_epoch,
                    codec_epoch,
                    display_id,
                    display_revision,
                    network,
                ),
            );
            emit_bound_event(
                &binding,
                "mediaTransportDiagnostic",
                native_media_transport_payload(
                    "routeStopped",
                    connection_epoch,
                    codec_epoch,
                    display_id,
                    display_revision,
                    transport,
                ),
            );
            emit_bound_event(
                &binding,
                "mediaControl",
                json!({
                    "command": "stopCapture",
                    "connectionEpoch": connection_epoch,
                    "codecEpoch": codec_epoch,
                    "displayId": display_id,
                }),
            );
        }
    }
    #[cfg(target_os = "macos")]
    {
        *scrap::quartz::ENABLE_RETINA.lock().unwrap() = true;
    }
}
