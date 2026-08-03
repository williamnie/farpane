# Phase 2 4K housekeeping smoke (stability pass, performance preflight fail)

This authenticated secure-direct run verifies the post-housekeeping Core and
reference-safe decoder at the required 4096x2304 encoded resolution. It is not
Phase 2 acceptance because its measured rate was below the 28 FPS target.

- Runtime: 180.12 seconds, ending only at the requested duration.
- Stream: 4,604 real Annex-B H265 frames at 4096x2304; zero packet gaps.
- Decode/presentation: 4,604 hardware-decoded NV12 IOSurface frames and 4,579
  Metal presentations; zero decode errors, reference drops, or decoder resets.
- Liveness: 25.56 encoded FPS, 25.42 presented FPS, 116.69 ms maximum
  unpresented age while receiving, and 0 ms final encoded-to-presentation lag.
- Backpressure: maximum queue depth two and 15.08 ms maximum bounded drain.
- Process: Intel UHD Graphics 630; 6.12% process CPU and 1.13 MiB steady-state
  RSS growth.

The Mac mini motion source was subsequently replaced with a Core Animation
source to avoid the software-decoding load that limited this preflight.

No peer ID, server address, server public key, password, token, or complete
authentication message is present in these artifacts.
