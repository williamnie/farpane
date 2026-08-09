# H5.2h Same-session recovery ownership

## Outcome

The final automatic H5.2 recovery checkpoint is complete. The existing product
chain already revalidates Accessibility trust before restoring input, retires
the exact media route while the Aqua session is unavailable, retries capture
with bounded backoff, and isolates the replacement Swift pipeline from late
callbacks belonging to the retired route.

The remaining allocator gap is now closed: native media connection and codec
epochs advance monotonically and fail closed at exhaustion. They can no longer
wrap to zero or reuse an earlier route identity.

## Contract verified and strengthened

- Every authenticated Remote connection observes the current Accessibility
  and active-Aqua authorities on the existing one-second lifecycle timer.
  Temporary Aqua loss arms same-session input recovery only while TCC remains
  trusted. TCC revocation clears that arm and latches input unavailable; a later
  system regrant cannot silently elevate the old connection.
- The native monitor service rechecks active Aqua before route creation and on
  every service iteration. Limited state exits the run loop, and
  `NativeRouteGuard` removes the exact broker route and emits its final
  diagnostics plus exact `stopCapture`.
- The pinned `GenericService` retry loop starts at 60 ms, doubles on immediate
  failure, and caps at 1,000 ms. It therefore preserves the subscriber without
  busy-spinning while the session is unavailable.
- A recovered run creates a new queue and allocates new connection/codec
  epochs before emitting `startCapture + reconfigure`. The checked atomic
  allocator refuses exhaustion instead of wrapping.
- The Swift route owner serially cancels and drains the previous SCK/VT
  pipeline before starting its replacement. Route identity plus an internal
  generation rejects late access units, encoder state, and failures from the
  retired pipeline.
- Session-availability audit schema 6 now machine-checks this complete chain.
  The earlier display-reconfigure audit was updated to recognize the same
  checked allocator rather than the removed raw `fetch_add` spelling.

## Verification

- Rust media-epoch exhaustion test: 1 passed, 0 failed.
- Rust Aqua/TCC recovery-state test: 1 passed, 0 failed.
- Fresh Rust `rdn-native-core,rdn-native-host` library suite: 149 passed,
  0 failed.
- Swift old-route drain and late-callback rejection test: 1 passed, 0 failed.
- Fresh `swift test`: 832 passed, 4 conditional built-core tests skipped,
  0 failed.
- Fresh arm64 Core build succeeded. With that dylib explicitly loaded,
  `swift test` passed 832 tests with 0 skipped and 0 failed.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  28 passed, 0 failed.
- Session audit schema 6 reports
  `same-session-recovery-ownership-verified` with no missing evidence.
- `swift build -c release --arch arm64` succeeded. The rebuilt Core is an
  arm64 Mach-O dylib and passed strict code-signature verification.
- Canonical RustDesk and `hbb_common` patches passed reverse-apply checks;
  both tracked bridge mirrors match their Vendor copies byte-for-byte; nested
  and root `diff --check` checks passed.

## Remaining boundary

- The installed-build lock/unlock, LoginWindow/no-user-login, Fast User
  Switching, TCC continuity, old-route stop/new-route start, and zero
  input/media leakage matrix still requires real-Mac observation.
- Secure Input remains a separate capability decision.
- This checkpoint does not claim that H5.2 real-Mac acceptance is complete.

No App/Agent was installed, launched, registered, or deployed. No Hermes,
server key, CI, dependency, database, real TCC state, or user configuration was
changed.
