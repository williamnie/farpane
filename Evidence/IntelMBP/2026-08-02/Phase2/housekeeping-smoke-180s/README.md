# Phase 2 housekeeping recovery smoke (diagnostic pass)

This authenticated Hermes-to-Mac-mini run verifies the post-fix secure-direct
transport and reference-safe live decoder for 180 seconds on the Intel MBP.
It is a successful recovery diagnostic, but it is not Phase 2 acceptance
because the remote display was still in the 2048x1152 low-resolution mode.

- Runtime: 180.08 seconds; secure direct transport remained connected until
  the requested duration ended.
- Stream: 4,780 real Annex-B H265 packets/frames at 2048x1152; one packet
  carried VPS/SPS/PPS and an IDR; zero packet sequence gaps.
- Decode/presentation: 4,780 hardware-decoded NV12 IOSurface frames and 4,752
  Metal presentations; zero decode errors, reference-frame drops, decoder
  resets, or keyframe recovery requests.
- Liveness: 26.54 encoded FPS, 26.39 presented FPS, 131.73 ms maximum
  unpresented age while receiving, and 0 ms final encoded-to-presentation
  staleness.
- Backpressure: maximum queue depth 2, four bounded drains, 5.56 ms maximum
  drain wait.
- Process: Intel UHD Graphics 630; 5.48% average process CPU; 28.37 MiB final
  RSS; 0.52 MiB steady-state growth.

No peer ID, server address, server public key, password, token, or complete
authentication message is present in these artifacts.
