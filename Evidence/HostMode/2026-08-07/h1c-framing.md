# H1c framing and IDR evidence

- Date: 2026-08-07 (Asia/Shanghai)
- Scope: offline/provisional framing plus local hardware IDR behavior

## Passing evidence

- AVCC4 and Annex-B fixture decode to identical ordered H.264 NAL units `[SPS(7), PPS(8), IDR(5)]` and round-trip deterministically.
- Truncated/zero-length AVCC and malformed/empty Annex-B fail closed.
- Two real VideoToolbox H.264 outputs parse as AVCC4 IDR access units containing SPS and PPS.
- A real VideoToolbox HEVC hardware session produced two 4-byte AVCC access units in 0.095 seconds; both startup and requested keyframes contained VPS, SPS and PPS, runtime readback reported hardware acceleration with no software fallback, and the existing HEVC packet parser accepted both outputs.
- `HostMediaPipelineTests` ran two authorized ScreenCaptureKit paths in 0.445 seconds: explicit H.264 selection produced only an H.264 hardware access unit, and explicit H.265 selection produced only an HEVC hardware access unit with VPS/SPS/PPS. Both retained the bounded raw-frame copy count and reported no software fallback.
- App capability wiring now advertises the independent hardware probes for both codecs, maps a validated Rust `reconfigure.codec + codecEpoch` to exactly one pipeline, and preserves that route codec on access-unit submission and encoder-state reporting. The CoreBridge contract parses both H.264 and H.265 reconfigure envelopes and rejects missing codec for reconfigure.
- The second output follows `requestKeyframe()` rather than encoder recreation, proving the pending IDR flag reaches the pipeline encode entry.
- Host media event tests reject unknown schema and zero epochs, and distinguish current versus stale route identities.
- Rust release build includes route-scoped `remoteRefresh` and `newSubscriber` request events and passed patch/release gates.
- Feature-gated Rust media tests passed 3/3, proving exact compressed-byte/keyframe/PTS/display mapping into the existing protobuf message, fail-closed codec mismatch handling, and sanitized milestone payloads.
- Swift strictly decodes route-scoped writer-dispatched, frame-acknowledged and Refresh-keyframe-dispatched milestones; the final full suite passed 50 tests with 0 failures.
- An initial `Scripts/preflight-host-mode-h1-golden.sh` run proved the source release build, sanitized-diagnostic contract and real SCK→hardware-H.264 path, but a later artifact audit found that it did not bind those checks to the App that would actually be launched. The preflight now also requires stable signing and exact Mach-O UUID matches for both the latest release executable and verified Host Core. A red/green verification rejected the stale installed App with exit 1, then accepted a temporary Apple Development-signed App containing the matching executable/Core and emitted `H1_GOLDEN_PREFLIGHT_READY`; its real SCK→hardware-H.264 test executed without a skip and passed in 0.350 seconds. The installed App still predates the current H1 work, so official-controller readiness remains pending until a newly built App passes this stronger gate.

## Deliberate limitation

The checked-in fixture is synthetic and labels itself provisional. The Rust wrapper test does not parse or decode the payload and therefore is not a wire-compatibility claim. App and pipeline now follow the Rust-selected codec/epoch, but no FarPane controller subscribed during this evidence run, so it does not establish a negotiated live route, final wire framing or remote Refresh recovery. Those remain manual Golden Connection gates, not inferred passes.

## First FarPane live attempt and CM regression

- A real old FarPane Viewer → Mac mini Host attempt reached password submission but produced one additional FarPane GUI/Dock instance per connection attempt and no remote picture.
- Source tracing identified the extra process deterministically: `Connection::start_ipc` falls back to `run_me(["--cm"])`, and `run_me` launches `current_exe`; FarPane did not implement a separate `--cm` mode.
- The feature-gated fix suppresses external CM startup only while the native Host media binding is active. The unbound/Viewer path still requires CM, preserving upstream behavior outside Host Mode.
- Fresh verification after the fix: patch reverse-apply and diff checks passed; the Rust release unit test `native_host_does_not_require_external_connection_manager` passed 1/1; the rebuilt Host Core passed the full Host lifecycle test; the Swift suite passed 52/52 and the release build passed.
- The no-picture symptom remains open until the fixed package is retried on the Mac mini. This evidence does not infer video success from removal of the duplicate process.
