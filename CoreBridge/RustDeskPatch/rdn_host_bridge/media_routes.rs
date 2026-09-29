pub(crate) fn native_media_begin_route(
    display_id: u64,
    codec: u32,
    width: u32,
    height: u32,
    fps: u32,
    bitrate: u32,
) -> Result<NativeMediaRoute, &'static str> {
    let (sender, receiver) = sync_channel(MEDIA_QUEUE_CAPACITY);
    let queue_telemetry = Arc::new(NativeMediaQueueTelemetry::default());
    let writer_telemetry = Arc::new(NativeMediaWriterTelemetry::default());
    let network_telemetry = Arc::new(NativeMediaNetworkTelemetry::default());
    let transport_telemetry = Arc::new(NativeMediaTransportTelemetry::default());
    let connection_epoch = next_native_media_epoch(&NEXT_CONNECTION_EPOCH)
        .ok_or("native media connection epoch is exhausted")?;
    let codec_epoch = next_native_media_epoch(&NEXT_CODEC_EPOCH)
        .ok_or("native media codec epoch is exhausted")?;
    let (binding, display_revision, display_reconfigure) = {
        let mut broker = MEDIA_BROKER.lock().unwrap();
        let binding = broker
            .binding
            .clone()
            .ok_or("native host media is not bound")?;
        let capable = match codec {
            MEDIA_CODEC_H264 => broker.capabilities.h264_hardware,
            MEDIA_CODEC_H265 => broker.capabilities.h265_hardware,
            _ => false,
        };
        if !capable {
            return Err("negotiated codec is not available from native adapter");
        }
        if width == 0
            || height == 0
            || fps == 0
            || width > broker.capabilities.max_width
            || height > broker.capabilities.max_height
            || fps > broker.capabilities.max_fps
        {
            return Err("display requirements exceed native adapter capabilities");
        }
        let display_reconfigure = broker.pending_display_reconfigures.remove(&display_id);
        let display_revision = match display_reconfigure {
            Some(provenance) => provenance
                .previous_display_revision
                .checked_add(1)
                .ok_or("native media display revision is exhausted")?,
            None => broker
                .display_revisions
                .get(&display_id)
                .copied()
                .unwrap_or(1),
        };
        broker
            .display_revisions
            .insert(display_id, display_revision);
        broker.routes.insert(
            display_id,
            MediaRoute {
                connection_epoch,
                codec_epoch,
                display_revision,
                codec,
                sender,
                queue_telemetry: queue_telemetry.clone(),
                writer_telemetry: writer_telemetry.clone(),
                network_telemetry: network_telemetry.clone(),
                transport_telemetry: transport_telemetry.clone(),
                last_pts_us: None,
                needs_parameter_sets: true,
            },
        );
        (binding, display_revision, display_reconfigure)
    };
    let codec_name = if codec == MEDIA_CODEC_H264 {
        "h264"
    } else {
        "h265"
    };
    let mut start_payload = json!({
        "command": "startCapture",
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
    });
    let mut reconfigure_payload = json!({
        "command": "reconfigure",
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
        "codec": codec_name,
        "width": width,
        "height": height,
        "fps": fps,
        "bitrate": bitrate,
    });
    if let Some(provenance) = display_reconfigure {
        start_payload["displayReconfigure"] = provenance.payload();
        reconfigure_payload["displayReconfigure"] = provenance.payload();
    }
    emit_bound_event(&binding, "mediaControl", start_payload);
    emit_bound_event(&binding, "mediaControl", reconfigure_payload);
    Ok(NativeMediaRoute {
        connection_epoch,
        codec_epoch,
        display_id,
        display_revision,
        codec,
        receiver,
        queue_telemetry,
        writer_telemetry,
        network_telemetry,
        transport_telemetry,
    })
}

/// Marks only the exact active monitor route whose pinned display inventory
/// comparison observed a change. The next replacement route consumes this
/// marker; codec/subscriber/service retries never synthesize one.
pub(crate) fn native_media_mark_display_reconfigure(
    route: &NativeMediaRoute,
) -> Result<(), &'static str> {
    let (binding, provenance) = {
        let mut broker = MEDIA_BROKER.lock().unwrap();
        let current = broker
            .routes
            .get(&route.display_id)
            .ok_or("native media display route is unavailable")?;
        if current.connection_epoch != route.connection_epoch
            || current.codec_epoch != route.codec_epoch
            || current.display_revision != route.display_revision
        {
            return Err("native media display route is stale");
        }
        if route.display_revision == u64::MAX
            || broker
                .pending_display_reconfigures
                .contains_key(&route.display_id)
        {
            return Err("native media display reconfigure is unavailable");
        }
        let generation = next_native_media_epoch(&NEXT_DISPLAY_RECONFIGURE_GENERATION)
            .ok_or("native display reconfigure generation is exhausted")?;
        let binding = broker
            .binding
            .clone()
            .ok_or("native host media is not bound")?;
        let provenance = NativeDisplayReconfigureProvenance {
            generation,
            previous_display_revision: route.display_revision,
            previous_connection_epoch: route.connection_epoch,
            previous_codec_epoch: route.codec_epoch,
        };
        broker
            .pending_display_reconfigures
            .insert(route.display_id, provenance);
        (binding, provenance)
    };
    emit_bound_event(
        &binding,
        "mediaDisplayReconfigureStarted",
        json!({
            "displayReconfigureGeneration": provenance.generation,
            "displayId": route.display_id,
            "previousDisplayRevision": provenance.previous_display_revision,
            "previousConnectionEpoch": provenance.previous_connection_epoch,
            "previousCodecEpoch": provenance.previous_codec_epoch,
        }),
    );
    Ok(())
}

fn next_native_media_epoch(counter: &AtomicU64) -> Option<u64> {
    counter
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |current| {
            current.checked_add(1)
        })
        .ok()
}

pub(crate) fn native_media_record_dequeued(route: &NativeMediaRoute) {
    route.queue_telemetry.record_dequeued();
}

pub(crate) fn native_media_report_queue_depth(route: &NativeMediaRoute) {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaQueueDiagnostic",
            native_media_queue_payload(
                "sample",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.queue_telemetry.snapshot(),
            ),
        );
    }
}

pub(crate) fn native_media_record_writer_cycle(
    route: &NativeMediaRoute,
    subscriber_count: usize,
    dispatch_wall: Duration,
    confirmation_wait: Duration,
    confirmation_complete: bool,
) {
    route.writer_telemetry.record(
        subscriber_count,
        dispatch_wall,
        confirmation_wait,
        confirmation_complete,
    );
}

pub(crate) fn native_media_report_writer_timing(route: &NativeMediaRoute) {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaWriterDiagnostic",
            native_media_writer_payload(
                "sample",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.writer_telemetry.snapshot(),
            ),
        );
    }
}

pub(crate) fn native_media_report_network(
    route: &NativeMediaRoute,
    subscriber_count: usize,
    qos_subscriber_count: usize,
    delay_sampled_subscribers: usize,
    rtt_sampled_subscribers: usize,
    response_delayed_subscribers: usize,
    worst_network_delay_ms: Option<u32>,
    worst_rtt_ms: Option<u32>,
) {
    if !route.network_telemetry.record(
        subscriber_count,
        qos_subscriber_count,
        delay_sampled_subscribers,
        rtt_sampled_subscribers,
        response_delayed_subscribers,
        worst_network_delay_ms,
        worst_rtt_ms,
    ) {
        return;
    }
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaNetworkDiagnostic",
            native_media_network_payload(
                "sample",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.network_telemetry.snapshot(),
            ),
        );
    }
}

pub(crate) fn native_media_report_transport(
    route: &NativeMediaRoute,
    subscriber_count: usize,
    direct_subscribers: usize,
    relay_subscribers: usize,
    unknown_subscribers: usize,
) {
    if !route.transport_telemetry.record(
        subscriber_count,
        direct_subscribers,
        relay_subscribers,
        unknown_subscribers,
    ) {
        return;
    }
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaTransportDiagnostic",
            native_media_transport_payload(
                "sample",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.transport_telemetry.snapshot(),
            ),
        );
    }
}
