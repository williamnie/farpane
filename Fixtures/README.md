# Phase 1 H265 fixtures

Run `Scripts/generate-fixtures.sh` on a Mac with FFmpeg VideoToolbox support.
It produces two two-second, 60-frame, Main-profile HEVC Annex-B streams:

- `2048x1152 @ 30 FPS`
- `4096x2304 @ 30 FPS`

The bitstream filter inserts one AUD per access unit and writes 30 Hz timing,
BT.709 colour metadata, a matching `ffprobe` JSON file and a SHA-256 file.
The raw fixtures are generated artifacts and are intentionally not committed.
The viewer loops each fixture from its IDR frame for the duration of a run.

`ffprobe` reports `r_frame_rate=30/1`. Raw HEVC has no container duration, so
some FFmpeg versions report a demuxer-default `avg_frame_rate=25/1`; the source
filter, SPS timing, frame count and scheduler are all explicitly 30 FPS.

