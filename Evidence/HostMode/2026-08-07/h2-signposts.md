# H2.1.1–H2.1.4 Host media telemetry evidence

- Date: 2026-08-07 (Asia/Shanghai)
- Scope: production signpost wiring through the Swift Host pipeline and Rust queue boundary
- Privacy: normalized PTS and compressed byte count only

## Fresh verification

- `HostMediaPipelineTests` executed real authorized ScreenCaptureKit → VideoToolbox paths for both H.264 and HEVC.
- Both tests correlated the first encoded access unit to exactly `capture`, `encodeSubmit`, `packetReady` in order using the same normalized PTS.
- Each `packetReady` byte count equaled the delivered access-unit byte count.
- The production App compiled with `sendSubmit`, `sendAccepted` and `sendDropped` around the Host Media ABI submission result.
- A bounded per-route snapshot now records requested/capture geometry and FPS, pixel format, callbacks/valid frames, optional dirty area ratio, raw-copy count, encode in-flight and p50/p95/p99 latency, packets/bytes/bitrate/keyframes, send outcomes, runtime and actual VideoToolbox hardware state.
- Targeted tests exercised both real H.264 and HEVC hardware pipelines and asserted the snapshot against the emitted access unit and encoder readback.
- A deterministic send-outcome test proved accepted/dropped counts and that a synchronous encode rejection removes its PTS from in-flight accounting.
- The native process sampler returned non-zero resident memory, physical footprint and thread count, plus bounded thermal/power enums; telemetry retained latest/peak values.
- A 1.2-second real timer test confirmed the active-route sampler executes automatically on its one-second cadence.
- `Scripts/sample-farpane-host-performance.sh` added a fail-closed system-side sampler for an explicitly selected Host PID, WindowServer, videotoolboxd, VTEncoderXPCService, system CPU, memory pressure, power source and Host sleep assertions.
- A real three-second smoke run produced three data rows with the expected 25 columns and parseable JSON metadata. The target PID was the test shell, so this proves sampler execution and schema only; it is not FarPane performance evidence.
- Acceptance mode rejects runs shorter than 600 seconds (1,800 seconds for stability), and the script refuses to overwrite an existing evidence prefix.

## Limitation

This is code and live capture/encode/process-sampling test evidence, not an Instruments performance trace. Capture FPS, bitrate, dirty area, FarPane CPU/resident/footprint/threads and thermal/power are represented in the snapshot, and the system-side sampler schema is executable, but no FarPane performance value is claimed from the short smoke window. `top` POWER is a relative impact metric, not joules or whole-system physical energy. Rust writer duration/queue depth, encryption/send CPU, RTT/loss/transport, qualifying 10/30-minute system-side runs, Instruments energy/trace evidence and end-to-end latency remain open, so H2.1 is not complete.
