# HiDPI transition smoke (failed diagnostic, not acceptance)

This directory preserves the first post-recovery live smoke from the Intel MBP.
It is intentionally classified as failed diagnostic evidence and must not be
used as Phase 2 acceptance.

The real Hermes-to-Mac-mini session authenticated and streamed 1,390 Annex-B
H265 packets without sequence gaps. VideoToolbox hardware decode produced NV12
IOSurface-backed frames with zero decode errors. During the run, the user
enabled HiDPI on the Mac mini. Sanitized RustDesk host diagnostics place the
corresponding encoder/display transition at the same time: the encoded mode
changed from 2048x1152 to 4096x2304 and the H265 encoder was recreated.

The run then ended after 121.06 seconds instead of the requested 180 seconds.
It recorded one pre-drain-policy reference-frame recovery, an 11.70-second
maximum presentation gap, 17.98-second final presentation staleness, and the
Core state chain ended in `error` then `disconnected`. The acceptance wrapper
therefore rejected it. It simultaneously exercised a remote display-mode hot
change, which is outside the fixed-display Phase 2 acceptance boundary.

The subsequent implementation replaces normal queue-overflow recovery with a
bounded VideoToolbox drain so an HEVC reference picture is not discarded or a
remote encoder refresh requested merely because four async frames are pending.
A fresh fixed-HiDPI smoke and a successful 1800-second run remain required.

No peer ID, server address, server public key, password, token, or complete
authentication message is stored here.
