# 1152p direct connection reset (failed diagnostic, not acceptance)

This directory preserves the fixed 2048x1152 direct-session diagnostic. It is
failed evidence and must not be used as Phase 2 acceptance.

The ABI v2 Core identified a secure direct connection with 5 ms network delay.
It authenticated and received 1,099 Annex-B H265 frames without sequence gaps.
All 1,099 frames decoded through VideoToolbox hardware decode; 1,085 were
presented. There were zero decode errors, reference-frame drops, decoder resets,
or keyframe requests. Two bounded backpressure drains took at most 10.10 ms.

The session ended after 60.21 seconds instead of 180 seconds. The Core reported
the sanitized `connection-reset` category; at the same time the Mac mini host
closed its socket with `Operation timed out (os error 60)`. This confirms that
lowering the encoded mode from 4096x2304 to 2048x1152 did not remove the current
transport failure, while the native video pipeline itself remained clean.

The next isolation step is a greater-than-90-second original RustDesk client
connection over the same machines and network. If that also resets, the blocker
is external transport/host state; if it remains connected, the Bridge must
restore a missing RustDesk client-side housekeeping/control behavior.

No peer ID, server address, server public key, password, token, source address,
or complete authentication message is stored here.
