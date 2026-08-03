# 4K Hermes relay smoke (failed transport diagnostic, not acceptance)

This directory preserves the forced-relay Intel MBP diagnostic. It is failed
evidence and must not be used as Phase 2 acceptance.

The ABI v2 Core state explicitly identified a secure RustDesk relay session.
It authenticated, measured 10 ms network delay, and streamed real 4096x2304
Annex-B H265. All 373 received frames decoded through VideoToolbox hardware
decode with zero decode errors or reference-frame drops. The bounded decoder
drain ran six times with a maximum wait of 42.23 ms.

The session ended after 28.95 seconds instead of the requested 180 seconds.
While packets were arriving, presentation staleness reached 7.18 seconds. The
Mac mini's sanitized RustDesk host diagnostic closed the relay connection with
`deadline has elapsed`. The acceptance wrapper correctly rejected this run.

The next validation returns to a fixed 2048x1152 direct stream. The original
pre-fix run already proved that transport combination could remain connected
for 1800 seconds; it must now be rerun with the reference-safe decoder to prove
continuous presentation.

No peer ID, server or relay address, server public key, password, token, source
address, or complete authentication message is stored here.
