# H5.1p-a display reconfigure ownership audit

## Outcome

The installed-product display reconfigure acceptance is still outstanding, but
the automatic rebuild path is already present and its ownership is now frozen
by an executable audit. The pinned RustDesk monitor video service—not AppKit,
CoreGraphics callbacks, or the Swift media pipeline—is the authoritative
display-change detector.

The wire `displayId` is a RustDesk display index, not a stable macOS
`CGDirectDisplayID`. A macOS display callback therefore must never replay an old
index or independently choose a replacement screen. At most it may wake the
existing Rust authority sooner; correctness continues to depend on the pinned
display inventory comparison and `SWITCH` rebuild.

This step does not add a second display observer, mutate Host ABI/wire schema,
or claim real hot-plug/resolution/rotation acceptance.

## Authoritative chain

1. The native monitor service snapshots the current RustDesk display info
   before starting a native route.
2. While subscribed, it compares the same display index against fresh
   `display_service::get_display_info` results. Inequality sends the upstream
   display-changed message to current and joining subscribers, then exits with
   `SWITCH`.
3. `NativeRouteGuard` retires the exact old connection/codec epoch and emits
   `stopCapture` before the pinned `GenericService` retry loop invokes the
   monitor callback again.
4. The replacement callback reads current dimensions, allocates fresh
   connection and codec epochs, and emits typed `startCapture` plus
   `reconfigure` controls.
5. Swift maps the fresh RustDesk display index into a newly enumerated
   `SCShareableContent` result. An out-of-range index fails closed; the route
   owner rejects late callbacks whose generation or exact identity no longer
   matches.

This preserves a single authority across reorder, resolution, rotation, and
display disappearance. It also explains why a bare CoreGraphics callback
cannot safely rebuild the Swift route: it observes canonical display IDs while
the active media contract is index-based.

## Machine-readable audit

`Scripts/audit-host-display-reconfigure-contract.py` verifies the tracked
native Host patch, tracked Rust/Swift bridge and pipeline sources, and the
unmodified `service.rs` blob from the exact pinned RustDesk commit. It emits
compact JSON and fails if:

- the monitor stops using the pinned subscribed-service restart loop;
- display comparison, subscriber notification, or `SWITCH` ordering drifts;
- exact old-route retirement loses its epoch checks;
- replacement routes stop receiving fresh epochs/current dimensions;
- Swift stops re-enumerating ScreenCaptureKit content and bounds-checking the
  display index;
- late-generation rejection or the acceleration-only callback decision drifts.

## Verification

- `python3 Scripts/audit-host-display-reconfigure-contract.py`:
  `ownership-frozen`, no missing evidence.
- `python3 -m unittest Tests.ScriptTests.test_host_display_reconfigure_contract_audit`:
  1 test, 0 failures.
- `swift test`: 820 tests, 4 conditional skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  27 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- Canonical RustDesk and `hbb_common` patches passed reverse-apply checks; both
  tracked bridge mirrors matched their Vendor copies byte-for-byte.
- `git diff --check`: passed before staging.

## Remaining boundary

- On an installed Mac, test resolution/scale/rotation changes and physical or
  virtual display attach/detach during an active session. Verify that the old
  route stops, the Viewer receives display-changed state, the replacement route
  has fresh epochs, and video resumes on the intended RustDesk display index.
- An optional CoreGraphics/ScreenCaptureKit callback may later reduce detection
  latency, but it may only signal the pinned Rust service; it must not select a
  display, mutate route epochs, or directly rebuild SCK/VideoToolbox.
- Explicit multi-display selection and revisioned mapping remain H6.4, not
  H5.1 recovery.
- No App/Agent was installed, launched, registered, or deployed; no real
  display, TCC state, Hermes configuration, server key, or user file changed.
