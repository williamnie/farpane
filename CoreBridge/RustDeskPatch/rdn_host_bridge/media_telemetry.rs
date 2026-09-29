pub(crate) struct NativeMediaAccessUnit {
    pub(crate) codec: u32,
    pub(crate) framing: u32,
    pub(crate) pts_us: u64,
    pub(crate) keyframe: bool,
    pub(crate) has_parameter_sets: bool,
    pub(crate) data: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeMediaQueueDropReason {
    NetworkBackpressure,
    Shutdown,
}

#[derive(Default)]
struct NativeMediaQueueState {
    depth: usize,
    maximum_depth: usize,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct NativeMediaQueueSnapshot {
    current_depth: usize,
    maximum_depth: usize,
}

#[derive(Default)]
struct NativeMediaQueueTelemetry {
    state: Mutex<NativeMediaQueueState>,
}

impl NativeMediaQueueTelemetry {
    fn try_enqueue(
        &self,
        sender: &SyncSender<NativeMediaAccessUnit>,
        packet: NativeMediaAccessUnit,
    ) -> Result<(), (NativeMediaQueueDropReason, NativeMediaAccessUnit)> {
        // Hold the small counter lock across try_send so the receiver cannot
        // decrement before a successful enqueue has published its depth.
        let mut state = self.state.lock().unwrap();
        match sender.try_send(packet) {
            Ok(()) => {
                state.depth += 1;
                state.maximum_depth = state.maximum_depth.max(state.depth);
                Ok(())
            }
            Err(TrySendError::Full(packet)) => {
                Err((NativeMediaQueueDropReason::NetworkBackpressure, packet))
            }
            Err(TrySendError::Disconnected(packet)) => {
                Err((NativeMediaQueueDropReason::Shutdown, packet))
            }
        }
    }

    fn record_dequeued(&self) {
        let mut state = self.state.lock().unwrap();
        state.depth = state.depth.saturating_sub(1);
    }

    fn snapshot(&self) -> NativeMediaQueueSnapshot {
        let state = self.state.lock().unwrap();
        NativeMediaQueueSnapshot {
            current_depth: state.depth,
            maximum_depth: state.maximum_depth,
        }
    }
}

#[derive(Default)]
struct NativeMediaWriterState {
    cycles: u64,
    subscriber_dispatches: u64,
    dispatch_wall_total_us: u64,
    maximum_dispatch_wall_us: u64,
    confirmation_wait_total_us: u64,
    maximum_confirmation_wait_us: u64,
    completed_confirmations: u64,
    timed_out_confirmations: u64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct NativeMediaWriterSnapshot {
    cycles: u64,
    subscriber_dispatches: u64,
    dispatch_wall_total_us: u64,
    maximum_dispatch_wall_us: u64,
    confirmation_wait_total_us: u64,
    maximum_confirmation_wait_us: u64,
    completed_confirmations: u64,
    timed_out_confirmations: u64,
}

#[derive(Default)]
struct NativeMediaWriterTelemetry {
    state: Mutex<NativeMediaWriterState>,
}

impl NativeMediaWriterTelemetry {
    fn record(
        &self,
        subscriber_count: usize,
        dispatch_wall: Duration,
        confirmation_wait: Duration,
        confirmation_complete: bool,
    ) {
        if subscriber_count == 0 {
            return;
        }
        let dispatch_us = duration_microseconds(dispatch_wall);
        let confirmation_us = duration_microseconds(confirmation_wait);
        let mut state = self.state.lock().unwrap();
        state.cycles = state.cycles.saturating_add(1);
        state.subscriber_dispatches = state
            .subscriber_dispatches
            .saturating_add(subscriber_count.min(u64::MAX as usize) as u64);
        state.dispatch_wall_total_us = state.dispatch_wall_total_us.saturating_add(dispatch_us);
        state.maximum_dispatch_wall_us = state.maximum_dispatch_wall_us.max(dispatch_us);
        state.confirmation_wait_total_us = state
            .confirmation_wait_total_us
            .saturating_add(confirmation_us);
        state.maximum_confirmation_wait_us =
            state.maximum_confirmation_wait_us.max(confirmation_us);
        if confirmation_complete {
            state.completed_confirmations = state.completed_confirmations.saturating_add(1);
        } else {
            state.timed_out_confirmations = state.timed_out_confirmations.saturating_add(1);
        }
    }

    fn snapshot(&self) -> NativeMediaWriterSnapshot {
        let state = self.state.lock().unwrap();
        NativeMediaWriterSnapshot {
            cycles: state.cycles,
            subscriber_dispatches: state.subscriber_dispatches,
            dispatch_wall_total_us: state.dispatch_wall_total_us,
            maximum_dispatch_wall_us: state.maximum_dispatch_wall_us,
            confirmation_wait_total_us: state.confirmation_wait_total_us,
            maximum_confirmation_wait_us: state.maximum_confirmation_wait_us,
            completed_confirmations: state.completed_confirmations,
            timed_out_confirmations: state.timed_out_confirmations,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct NativeMediaNetworkSnapshot {
    subscriber_count: u64,
    qos_subscriber_count: u64,
    delay_sampled_subscribers: u64,
    rtt_sampled_subscribers: u64,
    response_delayed_subscribers: u64,
    worst_network_delay_ms: Option<u32>,
    worst_rtt_ms: Option<u32>,
}

#[derive(Default)]
struct NativeMediaNetworkTelemetry {
    latest: Mutex<NativeMediaNetworkSnapshot>,
}

impl NativeMediaNetworkTelemetry {
    fn record(
        &self,
        subscriber_count: usize,
        qos_subscriber_count: usize,
        delay_sampled_subscribers: usize,
        rtt_sampled_subscribers: usize,
        response_delayed_subscribers: usize,
        worst_network_delay_ms: Option<u32>,
        worst_rtt_ms: Option<u32>,
    ) -> bool {
        if qos_subscriber_count > subscriber_count
            || delay_sampled_subscribers > qos_subscriber_count
            || rtt_sampled_subscribers > delay_sampled_subscribers
            || response_delayed_subscribers > qos_subscriber_count
            || (delay_sampled_subscribers == 0) != worst_network_delay_ms.is_none()
            || (rtt_sampled_subscribers == 0) != worst_rtt_ms.is_none()
        {
            return false;
        }
        *self.latest.lock().unwrap() = NativeMediaNetworkSnapshot {
            subscriber_count: subscriber_count.min(u64::MAX as usize) as u64,
            qos_subscriber_count: qos_subscriber_count.min(u64::MAX as usize) as u64,
            delay_sampled_subscribers: delay_sampled_subscribers.min(u64::MAX as usize) as u64,
            rtt_sampled_subscribers: rtt_sampled_subscribers.min(u64::MAX as usize) as u64,
            response_delayed_subscribers: response_delayed_subscribers.min(u64::MAX as usize)
                as u64,
            worst_network_delay_ms,
            worst_rtt_ms,
        };
        true
    }

    fn snapshot(&self) -> NativeMediaNetworkSnapshot {
        *self.latest.lock().unwrap()
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct NativeMediaTransportSnapshot {
    subscriber_count: u64,
    direct_subscribers: u64,
    relay_subscribers: u64,
    unknown_subscribers: u64,
}

#[derive(Default)]
struct NativeMediaTransportTelemetry {
    latest: Mutex<NativeMediaTransportSnapshot>,
}

impl NativeMediaTransportTelemetry {
    fn record(
        &self,
        subscriber_count: usize,
        direct_subscribers: usize,
        relay_subscribers: usize,
        unknown_subscribers: usize,
    ) -> bool {
        let Some(classified_subscribers) = direct_subscribers.checked_add(relay_subscribers) else {
            return false;
        };
        let Some(all_subscribers) = classified_subscribers.checked_add(unknown_subscribers) else {
            return false;
        };
        if all_subscribers != subscriber_count {
            return false;
        }
        *self.latest.lock().unwrap() = NativeMediaTransportSnapshot {
            subscriber_count: subscriber_count.min(u64::MAX as usize) as u64,
            direct_subscribers: direct_subscribers.min(u64::MAX as usize) as u64,
            relay_subscribers: relay_subscribers.min(u64::MAX as usize) as u64,
            unknown_subscribers: unknown_subscribers.min(u64::MAX as usize) as u64,
        };
        true
    }

    fn snapshot(&self) -> NativeMediaTransportSnapshot {
        *self.latest.lock().unwrap()
    }
}

fn duration_microseconds(duration: Duration) -> u64 {
    duration.as_micros().min(u64::MAX as u128) as u64
}

fn try_enqueue_native_media(
    sender: &SyncSender<NativeMediaAccessUnit>,
    telemetry: &NativeMediaQueueTelemetry,
    packet: NativeMediaAccessUnit,
) -> Result<(), (NativeMediaQueueDropReason, NativeMediaAccessUnit)> {
    telemetry.try_enqueue(sender, packet)
}

#[derive(Clone, Copy)]
pub(crate) struct NativeMediaPacketMetadata {
    pub(crate) framing: u32,
    pub(crate) pts_us: u64,
    pub(crate) keyframe: bool,
    pub(crate) has_parameter_sets: bool,
}

impl NativeMediaAccessUnit {
    pub(crate) fn metadata(&self) -> NativeMediaPacketMetadata {
        NativeMediaPacketMetadata {
            framing: self.framing,
            pts_us: self.pts_us,
            keyframe: self.keyframe,
            has_parameter_sets: self.has_parameter_sets,
        }
    }
}

#[derive(Clone, Copy)]
pub(crate) enum NativeMediaMilestone {
    FirstPacketDispatched,
    FirstPacketAcknowledged,
    RefreshKeyframeDispatched,
}

pub(crate) struct NativeMediaRoute {
    pub(crate) connection_epoch: u64,
    pub(crate) codec_epoch: u64,
    pub(crate) display_id: u64,
    pub(crate) display_revision: u64,
    pub(crate) codec: u32,
    pub(crate) receiver: Receiver<NativeMediaAccessUnit>,
    queue_telemetry: Arc<NativeMediaQueueTelemetry>,
    writer_telemetry: Arc<NativeMediaWriterTelemetry>,
    network_telemetry: Arc<NativeMediaNetworkTelemetry>,
    transport_telemetry: Arc<NativeMediaTransportTelemetry>,
}

static NEXT_CONNECTION_EPOCH: AtomicU64 = AtomicU64::new(1);
static NEXT_CODEC_EPOCH: AtomicU64 = AtomicU64::new(1);
static NEXT_DISPLAY_RECONFIGURE_GENERATION: AtomicU64 = AtomicU64::new(1);

lazy_static::lazy_static! {
    static ref MEDIA_BROKER: Mutex<MediaBroker> = Mutex::new(MediaBroker::default());
    static ref APPROVAL_BROKER: Mutex<NativeApprovalBroker> =
        Mutex::new(NativeApprovalBroker::default());
    static ref SESSION_BROKER: Mutex<NativeSessionBroker> =
        Mutex::new(NativeSessionBroker::default());
}

fn emit_bound_event(binding: &MediaHostBinding, event_type: &str, payload: Value) {
    let Some(callback) = binding.callback else {
        return;
    };
    let envelope = json!({
        "schemaVersion": EVENT_SCHEMA_VERSION,
        "eventId": binding.event_id.fetch_add(1, Ordering::Relaxed),
        "eventType": event_type,
        "hostInstanceId": binding.instance_id,
        "sentAt": now_unix_millis(),
        "payload": payload,
    });
    let Some(encoded) = serde_json::to_vec(&envelope).ok() else {
        return;
    };
    unsafe {
        callback(
            binding.context as *mut c_void,
            encoded.as_ptr() as *const c_char,
            encoded.len(),
        )
    };
}

fn bounded_remote_metadata(value: String) -> String {
    let mut result = String::new();
    for character in value.chars().filter(|character| !character.is_control()) {
        if result.len() + character.len_utf8() > MAX_REMOTE_METADATA_BYTES {
            break;
        }
        result.push(character);
    }
    result
}

fn emit_native_approval_completion(completion: &NativeApprovalCompletion) {
    let signal = match completion.status {
        NativeApprovalFinalStatus::Approved => Some(crate::ipc::Data::Authorize),
        NativeApprovalFinalStatus::Rejected | NativeApprovalFinalStatus::Expired => {
            Some(crate::ipc::Data::Close)
        }
        NativeApprovalFinalStatus::Cancelled => None,
    };
    if let Some(signal) = signal {
        let _ = completion.pending.decision_sender.send(signal);
    }
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    if let Some(binding) = binding {
        emit_bound_event(
            &binding,
            "incomingConnectionResolved",
            json!({
                "connectionId": completion.pending.request.connection_id,
                "status": completion.status.as_str(),
            }),
        );
        emit_bound_event(&binding, "snapshotChanged", json!({}));
    }
}

fn expire_native_approval(connection_id: &str) {
    let completion = APPROVAL_BROKER
        .lock()
        .unwrap()
        .expire(connection_id, Instant::now());
    if let Some(completion) = completion {
        emit_native_approval_completion(&completion);
    }
}

pub(crate) fn native_host_begin_approval(
    core_connection_id: i32,
    remote_id: String,
    remote_name: String,
    remote_platform: String,
    requested_capabilities: Vec<String>,
    decision_sender: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
) -> NativeApprovalStartResult {
    let binding = MEDIA_BROKER.lock().unwrap().binding.clone();
    let Some(binding) = binding else {
        return NativeApprovalStartResult::Unavailable;
    };
    let requested_at_ms = now_unix_millis();
    let connection_id = format!("{}:{core_connection_id}", binding.instance_id);
    let request = NativeApprovalRequest {
        connection_id: connection_id.clone(),
        core_connection_id,
        remote_id: bounded_remote_metadata(remote_id),
        remote_name: bounded_remote_metadata(remote_name),
        remote_platform: bounded_remote_metadata(remote_platform),
        requested_at_ms,
        expires_at_ms: requested_at_ms.saturating_add(NATIVE_APPROVAL_TIMEOUT_MS),
        requested_capabilities,
    };
    let result = APPROVAL_BROKER
        .lock()
        .unwrap()
        .begin(PendingNativeApproval {
            request: request.clone(),
            deadline: Instant::now() + Duration::from_millis(NATIVE_APPROVAL_TIMEOUT_MS),
            decision_sender: decision_sender.clone(),
        });
    match result {
        NativeApprovalStartResult::Accepted => {
            emit_bound_event(
                &binding,
                "incomingConnectionRequest",
                request.event_payload(),
            );
            emit_bound_event(&binding, "snapshotChanged", json!({}));
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(NATIVE_APPROVAL_TIMEOUT_MS)).await;
                expire_native_approval(&connection_id);
            });
        }
        NativeApprovalStartResult::Busy
        | NativeApprovalStartResult::Finalized
        | NativeApprovalStartResult::Unavailable => {
            let _ = decision_sender.send(crate::ipc::Data::Close);
        }
        NativeApprovalStartResult::Existing => {}
    }
    result
}

pub(crate) fn native_host_resolve_approval(
    connection_id: &str,
    decision: NativeApprovalDecision,
) -> NativeApprovalResolveResult {
    let (result, completion) =
        APPROVAL_BROKER
            .lock()
            .unwrap()
            .resolve(connection_id, decision, Instant::now());
    if let Some(completion) = completion {
        emit_native_approval_completion(&completion);
    }
    result
}

pub(crate) fn native_host_cancel_approval(core_connection_id: i32) {
    let completion = APPROVAL_BROKER.lock().unwrap().cancel(core_connection_id);
    if let Some(completion) = completion {
        emit_native_approval_completion(&completion);
    }
}
