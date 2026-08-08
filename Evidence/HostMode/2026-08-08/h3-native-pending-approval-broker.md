# H3.2b1 native pending-request broker evidence

Date: 2026-08-08

## Outcome

The pinned RustDesk login lifecycle now routes native Host local-click authentication into a bounded in-process broker. This closes the missing receiver left by disabling the legacy Connection Manager, but it does not yet expose an App approve/reject surface.

## Implemented boundary

- One connection-scoped pending request at a time.
- A monotonic 30-second deadline; wall-clock timestamps are presentation only.
- Exactly one final status across approved, rejected, expired, cancelled, and Host reset paths.
- Approval before the deadline sends `Authorize`; reject/expiry sends `Close`; disconnect cancellation does not send a redundant signal.
- Busy, already-finalized, unsupported, and Host-unavailable requests close fail closed.
- Host bind/unbind resets the broker and closes any pending request.
- Only Remote connections under pinned `Click` or `Both` modes enter local approval. Password-only and non-Remote requests are rejected.
- Authentication failures are presentation-only for the legacy Connection Manager and never become native pending notifications.
- Remote ID, name, and platform are bounded to 256 UTF-8 bytes after control-character removal and marked `remoteMetadataTrust=untrusted`. Transport remains `unknown`; no raw address, password, key, or credential is emitted.
- Requested capabilities are selected from fixed local strings after reading the peer disable options.

## Verification

Fresh commands after the final fail-closed race fix:

```text
cargo test --manifest-path Vendor/rustdesk/Cargo.toml --lib \
  --features rdn-native-core,rdn-native-host native_approval -- --nocapture
result: 1 passed, 0 failed

cargo test ... native_host_pending_approval -- --nocapture
result: 1 passed, 0 failed

cargo test ... native_host_remote_slot -- --nocapture
result: 2 passed, 0 failed

./Scripts/build-rust-core.sh
result: release arm64 liblibrustdesk.dylib built successfully

RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test
result: 113 passed, 0 failed, built core loaded

swift build -c release
result: passed
```

`rustfmt`, canonical bridge mirror comparison, and vendored patch reverse-apply check also passed. The first Rust run failed because this crate consumes Tokio through `hbb_common`; the implementation was corrected to use that existing re-export without adding a dependency, then all final runs passed.

## Remaining boundary

H3.2 is not complete. HostSnapshot schema v2 has no pending request, the generic Host command boundary does not yet call approve/reject, and Swift has no incoming-request UI or rebuild recovery. The pinned upstream also has no exact password-and-local-approval (AND) mapping, so that product mode remains fail closed. Busy rejection currently closes safely but does not yet have a dedicated stable remote-facing reason.
