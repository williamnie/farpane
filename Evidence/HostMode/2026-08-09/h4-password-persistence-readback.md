# H4.4f permanent-password persistence readback

## Outcome

Permanent-password set and clear no longer trust the pinned upstream boolean as proof of persistence. After an accepted mutation, the Host bridge obtains the in-memory local verifier/salt snapshot, reopens the fixed private Host identity and options files through the existing descriptor-relative reader, and reports success only when the persisted verifier and salt match exactly.

If readback is missing, malformed, unsafe or stale, the command returns the existing sanitized storage error (`-20` / `permanent-password-storage-failed`). An active Host unbinds media, closes approval/session brokers, requests and joins the rendezvous runtime, rotates and hides the temporary password, and publishes `error` / `degraded` with `configuration.passwordPersistenceFailed`. It therefore cannot continue authenticating against an ephemeral in-memory verifier.

## Security boundary

- The password setter ABI, command/event/snapshot schemas and shared `hbb_common` API are unchanged.
- The private identity projection mirrors the pinned identity document, rejects unknown or wrong-typed fields, and returns only encrypted-ID presence plus an optional password-match boolean.
- Raw file bytes, the expected verifier/salt strings, identity strings, verifier/salt projection, key-pair bytes and confirmation-map keys are wiped through the existing libsodium-backed memory-zero path on every return. No verifier, salt, password, key or filesystem path is placed in Host results or snapshots.
- Readback is side-effect free. Failure does not repair, replace, remove or roll back either file; runtime shutdown is the fail-closed boundary.

## Key evidence

- Pure Rust fixtures cover exact set, exact clear with a retained salt, stale verifier, stale salt, stale clear, wrong-typed fields and unknown fields. Every case asserts that both input documents remain byte-identical.
- The built-core lifecycle starts and restarts a real throwaway Host, changes its private config directory to owner `0500`, then invokes the dedicated password ABI while the Host runtime is active. The pinned setter changes memory but cannot replace the identity file; readback returns `-20`, wipes the caller buffer, transitions the Host to `error` / `degraded`, and preserves both TOML files and the directory entry set exactly.
- Source-order coverage proves both set and clear perform mutation -> disk readback -> success, and that the mismatch path takes the runtime and records the bounded storage error.

## Verification

- `cargo test --manifest-path Vendor/rustdesk/Cargo.toml --lib --features rdn-native-core,rdn-native-host rdn_host_bridge::tests`: 27 tests, 0 failures.
- `./Scripts/build-rust-core.sh`: rebuilt the arm64 Release dylib successfully.
- Built-core `HostBridgeContractTests/testFullHostCoreLifecycle`: 1 test, 0 failures, including the real active-runtime write-denied branch.
- `CoreBridgeContractTests/testPermanentPasswordSuccessRequiresDiskReadbackAndMismatchStopsHost`: 1 test, 0 failures.
- `swift test`: 721 tests, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- Rust and Swift arm64 Release builds succeeded.

## Remaining boundary

- Fresh-descriptor readback proves current visibility, not power-loss durability. The pinned writer still lacks file/directory `fsync`, exclusive temporary creation and error-returning setters.
- The in-memory verifier is not rolled back after a persistence mismatch; instead the only Host runtime is synchronously stopped and the instance becomes terminal error. Recovery requires a fresh process/lifecycle after storage is writable.
- Host identity/keypair and verifier/salt remain co-located, without a Host schema version, migration authority or Keychain-backed verifier storage.
- Implementing a durable writer or versioned migration changes the shared storage contract and requires a separate checkpoint. Dual active sessions, App-restart ID stability and split-process resource budgets remain installed two-machine evidence.
- No real product Host storage was opened or changed. No App/Agent was installed, launched, registered or deployed; Hermes, CI, root dependencies and databases were untouched, and nothing was pushed.
