# H5.1k Host sleep/recovery ABI v8

> Historical checkpoint: this file records commit `5a61143`. H5.1l-a later
> exposes the three calls through `HostControlClient` and advances the
> rerunnable audit to schema 3; the implementation and verification below are
> the H5.1k state at that commit.

## Outcome

Host Control ABI version 8 and HostSnapshot schema version 6 now implement the Rust-owned registration and sleep-assertion half of H5.1 recovery. The three new exact-epoch calls are exported through the core, C header, dynamic shim, build symbol gate, and built-core lifecycle test:

1. `rdn_host_begin_sleep(host, epoch)` accepts only `current + 1`, publishes `suspending`, and signals the existing Rendezvous runtime to exit without joining it.
2. `rdn_host_finish_sleep(host, epoch)` accepts only the active suspending epoch, joins that runtime, then waits up to two seconds for the Rust wakelock thread to acknowledge assertion drop before publishing `suspended`.
3. `rdn_host_resume_after_wake(host, epoch)` accepts only the matching suspended epoch, reenables the Rust assertion owner and starts a fresh Rendezvous runtime as `pending/resuming`. Success never means ready.

Wrong, zero, stale, duplicate, future, and exhausted epochs fail closed. `rdn_host_stop` remains terminal and distinct: it still unbinds media/session and rotates the temporary password; none of those operations appear in the sleep ABI.

## Rust ownership and acknowledgement

- `HostRuntime` now separates `request_stop` from `join`; ordinary terminal stop composes both, while sleep uses them on opposite sides of the public begin/finish boundary.
- The existing connection-owned wakelock worker now consumes typed `Update`, `SuspendNativeHost`, `ResumeNativeHost`, and `ResetNativeHost` commands.
- `SuspendNativeHost` records one exact epoch, synchronously drops the platform `WakeLock`, blocks later connection-count updates from reacquiring it, and only then acknowledges the caller.
- `ResumeNativeHost` accepts only that epoch, clears suspension, and immediately recomputes authenticated/remote connection counts. `ResetNativeHost` clears a process-global worker left by an older Host handle and runs only after the current native Host media binding exists, so the thread pins native user-idle rather than upstream display-on policy.
- The assertion is still created and destroyed only inside RustDesk's authenticated-connection wakelock thread. Swift owns no second `IOPMAssertion` or power activity token.

## Snapshot and projection contract

Schema 6 adds strict `recoveryEpoch` and `recoveryStatus` fields while retaining `registrationStatus`. Recovery status is one of `running`, `suspending`, `suspended`, `resuming`, or `failed`.

The Swift decoder rejects schema 5, negative/fractional epochs, unknown states, and invalid state combinations. The sanitized HostAgent projection and snapshot-first XPC payload preserve the same typed epoch/status, so a later process composition can wait for `recoveryEpoch == expected`, `recoveryStatus == running`, and `registrationStatus == ready` without consulting event timing.

No availability publication or AppKit notification is wired in this step. The existing composition still has synchronous registration/available closures, and `HostControlClient` deliberately has no public sleep methods yet; the machine audit records both as the next boundary instead of substituting fake success.

## Verification

- `cargo test --manifest-path Vendor/rustdesk/Cargo.toml --lib --features rdn-native-core,rdn-native-host`: 145 tests, 0 failures.
- `Scripts/build-rust-core.sh`: succeeded; the published arm64 dylib exports all three ABI v8 sleep symbols.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test`: 758 tests, 0 skips, 0 failures. `HostBridgeContractTests` executed the actual `begin → finish → resume` lifecycle, exact-epoch rejections, schema transitions, shim availability, and temporary-password continuity against the new dylib.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 24 tests, 0 failures; the sleep recovery audit reports `contract-implemented` with no missing evidence.
- `swift build -c release --arch arm64`: succeeded.
- Clean pinned replay matched 16 RustDesk parent files, 2 `hbb_common` files, and both tracked bridge mirrors byte-for-byte.
- `git diff --check`: passed before staging.

## Remaining boundary

- H5.1l must expose the three ABI calls through `HostControlClient`, replace the product composition's synchronous registration closure with exact-epoch snapshot convergence, and publish available only after the same epoch is authoritative `running/ready`.
- Only after that boundary is cancellation-safe may `HostAgentProcess` construct the recovery composition and register real `NSWorkspace` sleep/wake notifications.
- Real macOS sleep/wake, an active remote session's assertion lifecycle, network transition, display/TCC rebuild, Mini/MBP behavior, LoginWindow, and energy impact remain manual/product acceptance work.
- No App/Agent was installed, launched, registered, deployed, or pushed. Hermes, CI, dependencies, databases, real TCC state, product configuration, and secrets were untouched.
