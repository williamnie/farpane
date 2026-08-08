# H2.3.1 Rust encoded queue backpressure evidence

- Date: 2026-08-07 (Asia/Shanghai)
- Scope: process-local `NativeMediaAccessUnit` queue only
- ABI impact: none

## Production policy

`rdn_host_media_submit_access_unit` now delegates its existing `SyncSender::try_send` boundary to one internal `try_enqueue_native_media` policy:

- full queue → internal `NetworkBackpressure` → existing `RDN_HOST_ERR_BACKPRESSURE`;
- disconnected receiver → internal `Shutdown` → existing `RDN_HOST_ERR_BAD_STATE`;
- successful enqueue alone updates `last_pts_us` and clears `needs_parameter_sets`;
- rejected packets are returned from the policy and no queued packet is removed or replaced.

Queue capacity remains three. The C header, ABI versions, numeric errors and feature surface are unchanged.

## Fresh focused verification

After synchronizing the tracked bridge into the pinned RustDesk checkout at commit `6c578292e8ebbbec708b76986ba8c4bc7c509747`, the following command executed the feature-gated Host bridge tests:

```zsh
cargo test --lib --features rdn-native-core,rdn-native-host rdn_host_bridge::tests
```

Result: 5 passed, 0 failed, 81 filtered out. The two new tests proved:

1. a full `[keyframe+parameter sets, delta, delta]` queue rejects the fourth packet as `NetworkBackpressure`, returns that packet unchanged and drains the original PTS/keyframe sequence in order;
2. a disconnected receiver classifies `Shutdown` and returns the rejected keyframe with its parameter-set flag intact.

The pinned upstream build emitted its existing warning set; warnings were not altered or suppressed in this step.

## Boundary

This evidence proves the process-local encoded queue does not use newest-wins and does not silently evict a queued potential reference frame. It does not prove behavior inside later RustDesk connection/encryption writers, ACK timeout handling, real network congestion, reset/flush/IDR recovery, or the remaining six-reason telemetry mapping.
