# Phase 2 authenticated freeze reproduction

This is a failed, authenticated 1800-second Hermes-to-Mac-mini run retained as
root-cause evidence. It is not Phase 2 acceptance evidence.

- The RustDesk state chain reached `authenticated` and `streaming`.
- The Core delivered 46,465 H265 Annex-B encoded frames at 25.81 FPS with no
  sequence gaps, at 2048x1152.
- VideoToolbox hardware decode and NV12 IOSurface output were established, but
  only 1,781 frames decoded and 1,760 presented.
- 44,680 asynchronous VideoToolbox decode errors followed, reproducing the
  user-observed frozen image while Core packets continued to arrive.
- The run remained alive for 1800.07 seconds with bounded queue depth and
  stable memory, which proves that process survival alone is not acceptance.

The follow-up ABI v2 recovery change propagates asynchronous VideoToolbox
errors, resets the failed decoder session, and asks the existing RustDesk
session to refresh the display and emit a keyframe.
