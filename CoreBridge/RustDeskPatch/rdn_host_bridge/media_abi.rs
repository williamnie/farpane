#[no_mangle]
pub extern "C" fn rdn_host_media_abi_version() -> u32 {
    HOST_MEDIA_ABI_VERSION
}

unsafe fn validate_media_instance(
    host: &RdnHost,
    abi_version: u32,
    instance_pointer: *const c_char,
) -> Result<(), i32> {
    if abi_version != HOST_MEDIA_ABI_VERSION {
        return Err(RDN_HOST_ERR_ABI_MISMATCH);
    }
    let instance_id = required_string(instance_pointer)?;
    if instance_id != host.instance_id {
        return Err(RDN_HOST_ERR_STALE_EPOCH);
    }
    if !matches!(host.state, RdnHostState::Starting | RdnHostState::Ready) {
        return Err(RDN_HOST_ERR_BAD_STATE);
    }
    Ok(())
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_media_set_capabilities(
    host: *mut RdnHost,
    capabilities: *const RdnHostEncoderCapabilities,
) -> i32 {
    let (Some(host), Some(capabilities)) = (host.as_ref(), capabilities.as_ref()) else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if let Err(code) = validate_media_instance(
        host,
        capabilities.abi_version,
        capabilities.host_instance_id,
    ) {
        return code;
    }
    if capabilities.h264_hardware > 1
        || capabilities.h265_hardware > 1
        || capabilities.h264_hardware + capabilities.h265_hardware == 0
        || !(16..=16_384).contains(&capabilities.max_width)
        || !(16..=16_384).contains(&capabilities.max_height)
        || !(1..=240).contains(&capabilities.max_fps)
    {
        return RDN_HOST_ERR_VALIDATION;
    }
    let mut broker = MEDIA_BROKER.lock().unwrap();
    let Some(binding) = broker.binding.as_ref() else {
        return RDN_HOST_ERR_BAD_STATE;
    };
    if binding.instance_id != host.instance_id {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    broker.capabilities = MediaCapabilities {
        h264_hardware: capabilities.h264_hardware == 1,
        h265_hardware: capabilities.h265_hardware == 1,
        max_width: capabilities.max_width,
        max_height: capabilities.max_height,
        max_fps: capabilities.max_fps,
    };
    scrap::codec::set_native_encoding_capabilities(
        broker.capabilities.h264_hardware,
        broker.capabilities.h265_hardware,
    );
    drop(broker);
    scrap::codec::Encoder::update(scrap::codec::EncodingUpdate::Check);
    host.emit_event(
        "mediaCapabilitiesChanged",
        json!({
            "h264Hardware": capabilities.h264_hardware == 1,
            "h265Hardware": capabilities.h265_hardware == 1,
            "maxWidth": capabilities.max_width,
            "maxHeight": capabilities.max_height,
            "maxFps": capabilities.max_fps,
        }),
    );
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_media_submit_access_unit(
    host: *mut RdnHost,
    access_unit: *const RdnHostEncodedAccessUnit,
) -> i32 {
    let (Some(host), Some(access_unit)) = (host.as_ref(), access_unit.as_ref()) else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if let Err(code) =
        validate_media_instance(host, access_unit.abi_version, access_unit.host_instance_id)
    {
        return code;
    }
    // Recheck the same Rust Aqua authority at the final encoded admission
    // boundary. This prevents a route-loop acknowledgement wait from allowing
    // post-transition payload copies or queue insertion.
    if !native_host_session_is_available() {
        return RDN_HOST_ERR_BAD_STATE;
    }
    if access_unit.data.is_null() || access_unit.length == 0 {
        return RDN_HOST_ERR_INVALID_ARG;
    }
    if access_unit.length > MAX_MEDIA_ACCESS_UNIT_BYTES {
        return RDN_HOST_ERR_PACKET_TOO_LARGE;
    }
    if !matches!(access_unit.codec, MEDIA_CODEC_H264 | MEDIA_CODEC_H265)
        || !matches!(
            access_unit.framing,
            MEDIA_FRAMING_ANNEX_B | MEDIA_FRAMING_AVCC
        )
        || access_unit.flags & !MEDIA_KNOWN_FLAGS != 0
    {
        return RDN_HOST_ERR_VALIDATION;
    }
    let keyframe = access_unit.flags & MEDIA_FLAG_KEYFRAME != 0;
    let has_parameter_sets = access_unit.flags & MEDIA_FLAG_PARAMETER_SETS != 0;
    if keyframe && !has_parameter_sets {
        return RDN_HOST_ERR_MISSING_PARAMETER_SETS;
    }
    // Copy before touching the queue so Swift may release its callback-scoped
    // VideoToolbox buffer as soon as this function returns.
    let data = std::slice::from_raw_parts(access_unit.data, access_unit.length).to_vec();
    let mut broker = MEDIA_BROKER.lock().unwrap();
    let Some(route) = broker.routes.get_mut(&access_unit.display_id) else {
        return RDN_HOST_ERR_BAD_STATE;
    };
    if route.connection_epoch != access_unit.connection_epoch
        || route.codec_epoch != access_unit.codec_epoch
        || route.display_revision != access_unit.display_revision
    {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    if route.codec != access_unit.codec {
        return RDN_HOST_ERR_CODEC_MISMATCH;
    }
    if route.needs_parameter_sets && !(keyframe && has_parameter_sets) {
        return RDN_HOST_ERR_MISSING_PARAMETER_SETS;
    }
    if route
        .last_pts_us
        .map(|last| access_unit.pts_us <= last)
        .unwrap_or(false)
    {
        return RDN_HOST_ERR_NON_MONOTONIC_PTS;
    }
    let packet = NativeMediaAccessUnit {
        codec: access_unit.codec,
        framing: access_unit.framing,
        pts_us: access_unit.pts_us,
        keyframe,
        has_parameter_sets,
        data,
    };
    match try_enqueue_native_media(&route.sender, &route.queue_telemetry, packet) {
        Ok(()) => {
            route.last_pts_us = Some(access_unit.pts_us);
            route.needs_parameter_sets = false;
            RDN_HOST_OK
        }
        Err((NativeMediaQueueDropReason::NetworkBackpressure, _)) => RDN_HOST_ERR_BACKPRESSURE,
        Err((NativeMediaQueueDropReason::Shutdown, _)) => RDN_HOST_ERR_BAD_STATE,
    }
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_media_report_encoder_state(
    host: *mut RdnHost,
    state: *const RdnHostEncoderState,
) -> i32 {
    let (Some(host), Some(state)) = (host.as_ref(), state.as_ref()) else {
        return RDN_HOST_ERR_INVALID_ARG;
    };
    if let Err(code) = validate_media_instance(host, state.abi_version, state.host_instance_id) {
        return code;
    }
    if !matches!(state.codec, MEDIA_CODEC_H264 | MEDIA_CODEC_H265)
        || state.hardware_accelerated > 1
        || state.software_fallback > 1
        || state.hardware_accelerated + state.software_fallback != 1
    {
        return RDN_HOST_ERR_VALIDATION;
    }
    let encoder_id = match required_string(state.encoder_id) {
        Ok(value) if !value.is_empty() && value.len() <= MAX_ENCODER_ID_BYTES => value,
        _ => return RDN_HOST_ERR_VALIDATION,
    };
    let broker = MEDIA_BROKER.lock().unwrap();
    let route_matches = broker.routes.values().any(|route| {
        route.connection_epoch == state.connection_epoch
            && route.codec_epoch == state.codec_epoch
            && route.codec == state.codec
    });
    drop(broker);
    if !route_matches {
        return RDN_HOST_ERR_STALE_EPOCH;
    }
    host.emit_event(
        "encoderStateChanged",
        json!({
            "connectionEpoch": state.connection_epoch,
            "codecEpoch": state.codec_epoch,
            "codec": if state.codec == MEDIA_CODEC_H264 { "h264" } else { "h265" },
            "hardwareAccelerated": state.hardware_accelerated == 1,
            "softwareFallback": state.software_fallback == 1,
            "encoderId": encoder_id,
        }),
    );
    RDN_HOST_OK
}

#[no_mangle]
pub unsafe extern "C" fn rdn_host_destroy(host: *mut RdnHost) {
    if host.is_null() {
        return;
    }
    let mut host = Box::from_raw(host);
    unbind_media_host();
    if let Some(mut runtime) = host.runtime.take() {
        let _ = runtime.stop();
    }
    if !matches!(host.state, RdnHostState::Stopped | RdnHostState::Error) {
        password_security::update_temporary_password();
    }
    HOST_INSTANCE_LIVE.store(false, Ordering::Release);
}
