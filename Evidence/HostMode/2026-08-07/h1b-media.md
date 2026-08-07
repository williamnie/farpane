# H1b native media evidence

- Date: 2026-08-07 (Asia/Shanghai)
- Host: arm64, macOS 15.7.7 (24G720), M4 Pro
- RustDesk upstream: 1.4.9 at `6c578292e8ebbbec708b76986ba8c4bc7c509747`
- Core artifact SHA-256: `522f90fe33d983dfe613022d15502f4ba7a094755e9d605966c453539fccabbf`

## Core and patch checks

`./Scripts/build-rust-core.sh` completed successfully after the H1b patch and its `nm` gate found all Host Media ABI v1 exports:

- `rdn_host_media_abi_version`
- `rdn_host_media_set_capabilities`
- `rdn_host_media_submit_access_unit`
- `rdn_host_media_report_encoder_state`

`git diff --check`, `git -C Vendor/rustdesk diff --check` and `git -C Vendor/rustdesk apply --check --reverse ../../CoreBridge/RustDeskPatch/upstream-1.4.9.patch` all exited 0. Viewer ABI remains v5 and Host ABI remains v2.

The feature-gated Rust media suite passed 3 tests with 0 failures. It proves the native writer wrapper preserves the exact H.264 compressed payload, keyframe flag, PTS and display index in the existing protobuf `VideoFrame`, rejects a packet whose codec differs from the negotiated codec before `GenericService::send_video_frame`, and emits only sanitized milestone metadata.

## Native capture and hardware encode

The test process already had macOS Screen Recording authorization; `CGPreflightScreenCaptureAccess()` returned true without requesting or changing permission.

`HostMediaPipelineTests/testAuthorizedScreenCaptureReachesHardwareEncoder` started a real ScreenCaptureKit stream, captured a desktop frame, submitted it to the VideoToolbox H.264 session and received a compressed access unit. The final full-suite run completed this test in 0.276 seconds and asserted:

- hardware encoder state was read only after the first successful callback;
- `hardwareAccelerated=true`, `softwareFallback=false`, encoder ID non-empty;
- first access unit was a keyframe with SPS/PPS and non-empty AVCC bytes;
- logical raw-frame copy count was at most 1, with no FarPane CPU full-frame conversion.

The independent H.264 test submitted two synthetic NV12 frames and proved both startup IDR and a later `requestKeyframe()` take effect, with parameter sets on both keyframes. Pixel-path tests prove `420f`/`420v` map to logical copy count 0, BGRA to one system pixel transfer, and unknown formats fail closed.

## ABI and lifecycle evidence

The Host lifecycle contract exercises capability ABI mismatch/acceptance and proves an access unit is rejected while no authoritative subscriber route exists. Swift event tests reject unknown schema, zero epochs and incomplete reconfigure payloads, and prove stale route epochs do not match the active route.

All Swift FFI calls that use the opaque Host pointer now hold the client lifetime lock through the call, so stop/destroy cannot race command, snapshot or media operations.

The release Swift build and final full suite passed with 50 tests and 0 failures. The focused live Hermes lifecycle regression against the final Core artifact passed in 2.300 seconds with two ready registrations and stable identity across full stop/destroy. Server address, hbbs public key, local ID and temporary password were not printed or persisted; the hbbs private key was not read. The throwaway test configuration root was absent after cleanup, and an exact-value scan confirmed the configured hbbs public key is absent from the worktree.

## Golden-connection observability

Rust now emits three route-scoped, low-frequency `mediaDiagnostic` milestones: first packet dispatched through the existing writer, first packet acknowledged through RustDesk's frame-fetched path, and Refresh-triggered keyframe dispatched. The envelope includes only route epochs, display revision, codec/framing, PTS, keyframe/parameter-set booleans and subscriber count. It deliberately excludes connection/peer IDs, encoded bytes, screen content, credentials and server material. Swift validates the schema and current route before showing these states on the Host home UI.

These milestones prove precise internal transport boundaries during the upcoming official-controller run. They do not claim the controller decoded or displayed the frame; visible remote output remains a separate manual assertion.

## Current verdict

H1b.1–H1b.3 implementation and local media-plane evidence pass. The H1b stage exit is intentionally still open: no second controller created an active Rust subscriber in this run, so Rust writer transmission and remote rendering are not claimed. That proof joins the official-controller golden connection in H1c.
