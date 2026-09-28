#[derive(Clone)]
struct MediaHostBinding {
    instance_id: String,
    callback: Option<RdnHostEventCallback>,
    context: usize,
    event_id: Arc<AtomicU64>,
}

#[derive(Clone, Copy, Default)]
struct MediaCapabilities {
    h264_hardware: bool,
    h265_hardware: bool,
    max_width: u32,
    max_height: u32,
    max_fps: u32,
}

struct MediaRoute {
    connection_epoch: u64,
    codec_epoch: u64,
    display_revision: u64,
    codec: u32,
    sender: SyncSender<NativeMediaAccessUnit>,
    queue_telemetry: Arc<NativeMediaQueueTelemetry>,
    writer_telemetry: Arc<NativeMediaWriterTelemetry>,
    network_telemetry: Arc<NativeMediaNetworkTelemetry>,
    transport_telemetry: Arc<NativeMediaTransportTelemetry>,
    last_pts_us: Option<u64>,
    needs_parameter_sets: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct NativeDisplayReconfigureProvenance {
    generation: u64,
    previous_display_revision: u64,
    previous_connection_epoch: u64,
    previous_codec_epoch: u64,
}

impl NativeDisplayReconfigureProvenance {
    fn payload(self) -> Value {
        json!({
            "displayReconfigureGeneration": self.generation,
            "previousDisplayRevision": self.previous_display_revision,
            "previousConnectionEpoch": self.previous_connection_epoch,
            "previousCodecEpoch": self.previous_codec_epoch,
        })
    }
}

#[derive(Default)]
struct MediaBroker {
    binding: Option<MediaHostBinding>,
    capabilities: MediaCapabilities,
    clipboard_transfer_policy: NativeClipboardTransferPolicy,
    #[cfg(target_os = "macos")]
    file_service_owner: Option<Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>>,
    routes: HashMap<u64, MediaRoute>,
    display_revisions: HashMap<u64, u64>,
    pending_display_reconfigures: HashMap<u64, NativeDisplayReconfigureProvenance>,
}
