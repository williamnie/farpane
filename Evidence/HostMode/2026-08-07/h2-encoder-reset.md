# H2.3.3 Encoder generation reset evidence

- Date: 2026-08-07 (Asia/Shanghai)
- Scope: Swift Host media pipeline reset after Rust encoded-queue backpressure
- ABI/schema impact: none

## Implemented boundary

- Each concrete VideoToolbox encoder receives a monotonically changing pipeline generation.
- Recovery invalidates the generation and removes the encoder under the pipeline lock before any session teardown begins.
- Old access-unit, state and error callbacks cannot reach the App/Rust submit boundary after invalidation; a synchronous encode failure from a capture callback that already held the old encoder is gated by the same generation.
- Completed old access units still settle encode/packet telemetry so in-flight accounting does not leak.
- `VTCompressionSessionCompleteFrames` and invalidation run on a dedicated serial queue outside the output callback that initiated recovery.
- The next captured frame creates a new H.264 or HEVC session whose first output is forced to an IDR with parameter sets.
- Pipeline stop drains the reset queue.

## Fresh focused verification

`swift test --filter HostMediaPipelineTests` executed five tests with zero failures:

- deterministic generation gate rejection after reset;
- real authorized ScreenCaptureKit → hardware H.264 baseline;
- real authorized ScreenCaptureKit → hardware HEVC baseline;
- real H.264 generation reset with replacement IDR + SPS/PPS;
- real HEVC generation reset with replacement IDR + VPS/SPS/PPS.

Both reset tests triggered recovery inside the first encoder output callback, observed a second pipeline access unit from the replacement generation, required monotonically increasing PTS, keyframe status and parameter sets, then stopped the pipeline after its reset queue drained.

## Boundary

This proves the local generation/session replacement behavior on the current authorized Mac. It does not force the Rust queue to fill, measure real congestion recovery time, or prove the later encrypted writer/remote decoder result. Six-reason drop telemetry and a real-link congestion scenario remain open H2.3 evidence.
