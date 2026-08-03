# Phase 3 AWDL-off motion preflight with 30Hz render cap

This real 180-second Hermes relay diagnostic used the continuous 30Hz motion
source after AWDL was disabled on the Intel MacBook Pro. It is retained as
failed preflight evidence and must not be represented as Phase 3 acceptance.

The run reached 32.98 encoded FPS and 29.55 presented FPS with a maximum
presentation gap of 130.98ms, zero decode faults and queues bounded at two.
The 0.8951 presented/encoded ratio narrowly missed the 0.90 gate because the
Rust core capture headroom delivered above 30 FPS while MTKView still polled at
30Hz. Connection credentials and endpoint identifiers are not recorded.
