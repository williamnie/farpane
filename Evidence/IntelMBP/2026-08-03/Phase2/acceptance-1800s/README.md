# Phase 2 live 4K acceptance — passed

This is the authoritative Phase 2 acceptance run on the Intel MacBook Pro. It
used the RustDesk 1.4.9 Core pinned to commit
`6c578292e8ebbbec708b76986ba8c4bc7c509747`, a secure relay through the configured
Hermes service, the real Mac mini 4096x2304 HiDPI desktop at 30 Hz, and the
native VideoToolbox -> NV12 IOSurface -> Metal/MTKView path.

The strict benchmark wrapper exited 0 after 1,800.142 seconds. Key evidence:

- 54,721 real H265 Annex-B packets/frames; VPS/SPS/PPS and an IDR observed.
- 54,721 hardware-decoded frames and 53,329 presented frames (97.456%).
- Active-stream encoded/presented FPS: 30.403 / 29.633.
- End-to-end FPS including connection setup: 30.398 / 29.625.
- Decode average/P95: 11.915 / 12.207 ms; render average/P95: 9.151 / 9.408 ms.
- 0 decode errors, reference-frame drops, decoder resets, keyframe requests,
  packet sequence gaps, non-H265 packets, non-NV12 frames, or missing IOSurfaces.
- Decoder queue max 2; renderer NV12 IOSurface queue max 2; maximum backpressure
  wait 22.952 ms; maximum receiving presentation age 174.375 ms.
- Average app CPU 5.020%; peak RSS 22.000 MB; steady RSS slope 0.056203 MB/min;
  early-vs-late steady window growth 1.141 MB.
- 1,801 resource samples cover elapsed seconds 0 through 1,800.

`report.json` is the pipeline report, `samples.csv` is the one-second process
sample series, `app.log` contains only sanitized state transitions, and
`validation.txt` is the independently calculated long-run gate summary. No
connection identifiers or credentials are persisted. Verify the files with
`shasum -a 256 -c SHA256SUMS` from this directory.
