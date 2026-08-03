# Phase 3 AWDL-off 60Hz renderer preflight

This is a successful real 180-second Hermes relay preflight from the Intel
MacBook Pro to the 4096x2304 Mac mini with the continuous 30Hz motion source.
It is diagnostic evidence, not the required 30-minute Phase 3 acceptance.

The run received 5,933 H265 frames at 33.01 FPS and presented 5,892 at 32.81
FPS for a 0.9931 ratio. It recorded zero decode faults, reference drops,
decoder resets, keyframe requests, packet gaps or rejected input events while
both queues remained bounded at two. The user visibly confirmed that motion
was substantially more stable after AWDL was disabled. Connection credentials
and endpoint identifiers are not recorded.
