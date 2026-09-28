fn native_media_queue_payload(
    kind: &str,
    connection_epoch: u64,
    codec_epoch: u64,
    display_id: u64,
    display_revision: u64,
    queue: NativeMediaQueueSnapshot,
) -> Value {
    json!({
        "kind": kind,
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
        "currentDepth": queue.current_depth,
        "maximumDepth": queue.maximum_depth,
        "capacity": MEDIA_QUEUE_CAPACITY,
    })
}

fn native_media_writer_payload(
    kind: &str,
    connection_epoch: u64,
    codec_epoch: u64,
    display_id: u64,
    display_revision: u64,
    writer: NativeMediaWriterSnapshot,
) -> Value {
    json!({
        "kind": kind,
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
        "cycles": writer.cycles,
        "subscriberDispatches": writer.subscriber_dispatches,
        "dispatchWallTotalUs": writer.dispatch_wall_total_us,
        "maximumDispatchWallUs": writer.maximum_dispatch_wall_us,
        "confirmationWaitTotalUs": writer.confirmation_wait_total_us,
        "maximumConfirmationWaitUs": writer.maximum_confirmation_wait_us,
        "completedConfirmations": writer.completed_confirmations,
        "timedOutConfirmations": writer.timed_out_confirmations,
    })
}

fn native_media_network_payload(
    kind: &str,
    connection_epoch: u64,
    codec_epoch: u64,
    display_id: u64,
    display_revision: u64,
    network: NativeMediaNetworkSnapshot,
) -> Value {
    json!({
        "kind": kind,
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
        "subscriberCount": network.subscriber_count,
        "qosSubscriberCount": network.qos_subscriber_count,
        "delaySampledSubscribers": network.delay_sampled_subscribers,
        "rttSampledSubscribers": network.rtt_sampled_subscribers,
        "responseDelayedSubscribers": network.response_delayed_subscribers,
        "worstNetworkDelayMs": network.worst_network_delay_ms,
        "worstRttMs": network.worst_rtt_ms,
    })
}

fn native_media_transport_payload(
    kind: &str,
    connection_epoch: u64,
    codec_epoch: u64,
    display_id: u64,
    display_revision: u64,
    transport: NativeMediaTransportSnapshot,
) -> Value {
    json!({
        "kind": kind,
        "connectionEpoch": connection_epoch,
        "codecEpoch": codec_epoch,
        "displayId": display_id,
        "displayRevision": display_revision,
        "subscriberCount": transport.subscriber_count,
        "directSubscribers": transport.direct_subscribers,
        "relaySubscribers": transport.relay_subscribers,
        "unknownSubscribers": transport.unknown_subscribers,
    })
}

pub(crate) fn native_media_request_idr(route: &NativeMediaRoute, reason: &str) {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaControl",
            json!({
                "command": "requestIdr",
                "connectionEpoch": route.connection_epoch,
                "codecEpoch": route.codec_epoch,
                "displayId": route.display_id,
                "displayRevision": route.display_revision,
                "reason": reason,
            }),
        );
    }
}

pub(crate) fn native_media_report_milestone(
    route: &NativeMediaRoute,
    milestone: NativeMediaMilestone,
    packet: NativeMediaPacketMetadata,
    subscriber_count: usize,
) {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    let Some(binding) = binding else { return };
    let Some(payload) = native_media_milestone_payload(route, milestone, packet, subscriber_count)
    else {
        return;
    };
    emit_bound_event(&binding, "mediaDiagnostic", payload);
}

fn native_media_milestone_payload(
    route: &NativeMediaRoute,
    milestone: NativeMediaMilestone,
    packet: NativeMediaPacketMetadata,
    subscriber_count: usize,
) -> Option<Value> {
    if subscriber_count == 0 {
        return None;
    }
    let kind = match milestone {
        NativeMediaMilestone::FirstPacketDispatched => "firstPacketDispatched",
        NativeMediaMilestone::FirstPacketAcknowledged => "firstPacketAcknowledged",
        NativeMediaMilestone::RefreshKeyframeDispatched => "refreshKeyframeDispatched",
    };
    let codec = match route.codec {
        MEDIA_CODEC_H264 => "h264",
        MEDIA_CODEC_H265 => "h265",
        _ => return None,
    };
    let framing = match packet.framing {
        MEDIA_FRAMING_ANNEX_B => "annexB",
        MEDIA_FRAMING_AVCC => "avcc",
        _ => return None,
    };
    Some(json!({
        "kind": kind,
        "connectionEpoch": route.connection_epoch,
        "codecEpoch": route.codec_epoch,
        "displayId": route.display_id,
        "displayRevision": route.display_revision,
        "codec": codec,
        "framing": framing,
        "ptsUs": packet.pts_us,
        "keyframe": packet.keyframe,
        "hasParameterSets": packet.has_parameter_sets,
        "subscriberCount": subscriber_count,
    }))
}

pub(crate) fn native_media_end_route(route: &NativeMediaRoute) {
    let binding = {
        let mut broker = MEDIA_BROKER.lock().unwrap();
        let matches = broker
            .routes
            .get(&route.display_id)
            .map(|current| {
                current.connection_epoch == route.connection_epoch
                    && current.codec_epoch == route.codec_epoch
            })
            .unwrap_or(false);
        if matches {
            broker.routes.remove(&route.display_id);
            broker.binding.clone()
        } else {
            None
        }
    };
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "mediaQueueDiagnostic",
            native_media_queue_payload(
                "routeStopped",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.queue_telemetry.snapshot(),
            ),
        );
        emit_bound_event(
            &binding,
            "mediaWriterDiagnostic",
            native_media_writer_payload(
                "routeStopped",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.writer_telemetry.snapshot(),
            ),
        );
        emit_bound_event(
            &binding,
            "mediaNetworkDiagnostic",
            native_media_network_payload(
                "routeStopped",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.network_telemetry.snapshot(),
            ),
        );
        emit_bound_event(
            &binding,
            "mediaTransportDiagnostic",
            native_media_transport_payload(
                "routeStopped",
                route.connection_epoch,
                route.codec_epoch,
                route.display_id,
                route.display_revision,
                route.transport_telemetry.snapshot(),
            ),
        );
        emit_bound_event(
            &binding,
            "mediaControl",
            json!({
                "command": "stopCapture",
                "connectionEpoch": route.connection_epoch,
                "codecEpoch": route.codec_epoch,
                "displayId": route.display_id,
            }),
        );
    }
}
