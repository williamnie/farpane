# Fixed-HiDPI direct smoke (failed transport diagnostic, not acceptance)

This directory preserves the second post-recovery Intel MBP smoke. HiDPI and
the 4096x2304 encoded mode remained fixed throughout the run. It is failed
diagnostic evidence and must not be used as Phase 2 acceptance.

The real Hermes-rendezvoused session used a direct peer connection. It
authenticated and received 2,919 Annex-B H265 frames without packet sequence
gaps. All 2,919 frames decoded through VideoToolbox hardware decode into NV12
IOSurface-backed buffers; 2,866 were presented. There were zero decode errors,
zero reference-frame drops, zero decoder resets, zero keyframe requests, zero
backpressure waits, and maximum decode queue depth was three. While encoded
packets were arriving, maximum presentation staleness was 0.85 seconds.

The direct TCP session stopped receiving video and ended in the sanitized Core
`error`/`disconnected` state after 131.44 seconds rather than the requested 180
seconds. The Mac mini observed the client side close the direct connection.
The acceptance wrapper correctly rejected the run. A subsequent Core build
adds sanitized transport/error classification, and the next diagnostic forces
the RustDesk Hermes relay path to isolate the direct-network failure.

No peer ID, server address, server public key, password, token, source address,
or complete authentication message is stored here.
