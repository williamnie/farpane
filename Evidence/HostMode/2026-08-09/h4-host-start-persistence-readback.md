# H4.4e Host start persistence readback gate

## Outcome

- Made Host startup success depend on securely re-reading the required identity and canonical server options from the fixed Host files after the pinned upstream setters return.
- Converted silent `confy` write failure or a stale persisted projection into the existing sanitized `-20` storage failure before media binding or network runtime creation.
- Kept the change inside the Host bridge: no shared `hbb_common` API/schema, Host ABI, Viewer storage or product bootstrap contract changed.

## Key evidence

- H4.4d's descriptor-based reader now returns only a minimal projection: whether the primary document carries a non-empty `enc_id`, and the public `Config2.options` map. It still strictly deserializes the exact pinned `Config`/`Config2` types first.
- The bounded raw file buffer is owned by `WipedHostStorageBytes` and is wiped through the existing libsodium-backed `password_security::memzero_secret` path on success and every error return.
- After `Config::set_option` installs rendezvous, relay, public-key and keep-awake policy, `Config::get_id` initializes the identity and `stop-service` is cleared, `verify_host_start_storage` re-opens both fixed files through the same safe reader.
- Startup requires a persisted non-empty encrypted ID plus exact persisted values for `custom-rendezvous-server`, optional `relay-server`, `key`, `keep-awake-during-incoming-sessions=Y`, and absence of the cleared `stop-service` key. Other upstream options remain untouched.
- The comparison never emits the server key, ID, paths or TOML/parser details. Failure exposes only `configuration.storagePersistenceFailed`, degraded/error state and the existing storage code.
- The gate runs before `bind_media_host` and `HostRuntime::start`, so an unpersisted startup cannot register, accept media or appear pending/ready.
- Pure fixtures prove exact projection success is read-only and that a missing identity or stale canonical option fails without creating or rewriting either document.
- The built-core lifecycle first proves normal first-start and restart behavior. It then makes the throwaway config directory owner-read/execute-only, changes the requested rendezvous server and invokes the real void upstream setter: `confy` cannot create its replacement, the readback returns `-20` with the exact persistence error, both TOML files remain byte-identical and the directory gains no temporary entry.

## Verification

- `cargo test --manifest-path Vendor/rustdesk/Cargo.toml --lib --features rdn-native-core,rdn-native-host host_storage_`: 7 tests, 0 failures.
- Complete `rdn_host_bridge::tests::` Rust group: 24 tests, 0 failures.
- `scripts/build-rust-core.sh`: rebuilt the arm64 Release dylib successfully.
- Built-core `HostBridgeContractTests/testFullHostCoreLifecycle`: 1 test, 0 failures, including the real write-denied/stale-readback branch and sanitized snapshot assertions.
- `CoreBridgeContractTests/testHostStoragePreflightPrecedesConfigMutationAndIdentityAccess`: 1 test, 0 failures; source order proves preflight → writes/identity → readback → media/runtime.
- `swift test`: 720 tests, 4 environment-gated skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- Rust and Swift arm64 Release builds succeeded.
- The tracked Host bridge exactly matches the vendor build source; both pinned patch reverse-apply checks and vendor `diff --check` checks pass.
- The throwaway `FarPaneHostTestsRoot.FarPaneHostTests` namespace is absent after verification; `git diff --check` is clean before scoped staging.

## Remaining boundary

- Readback proves the required bytes are visible through a fresh file descriptor; it does not prove power-loss durability. The pinned writer still lacks file/directory `fsync`, exclusive temporary creation and error-returning config setters.
- Permanent-password set/clear still trusts the upstream boolean even when the underlying void store fails. H4.4f can reuse the safe reader to compare the persisted verifier/salt and define a fail-closed active-runtime policy without changing shared schema.
- A genuinely durable writer and versioned migration authority require a separate shared-storage contract checkpoint; this step does not disguise either as complete.
- Identity/keypair and verifier/salt remain co-located and Host verifier storage is not Keychain-backed.
- Dual-active-session, App-restart Host ID stability and split-process resource budgets still require installed two-machine evidence.
- No real product Host storage was opened or changed; no App/Agent was installed, launched, registered or deployed. Hermes, CI and root dependencies were unchanged, and nothing was pushed.
