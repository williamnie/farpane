# H5.1o-b2 Host network restart ABI v9

## Outcome

HostCore now exposes an identity-preserving, exact-generation registration
restart operation. Host ABI advances from version 8 to 9 while snapshot schema
remains version 6. `rdn_host_recover_network_path(host, path_generation)` is
exported through the Rust bridge, C header, dynamic shim, core build symbol
gate, golden preflight symbol gate, and built-core lifecycle test.

The operation accepts only the exact next nonzero generation while the Host is
`starting` or `ready`, sleep recovery is `running`, and the registration
runtime exists. It commits that generation, publishes `starting/pending`,
synchronously stops and joins the old Rendezvous runtime (which resets old
online state), then starts a new runtime with the same pinned rendezvous
server. Success means accepted/pending, never ready.

## Key evidence

- `RdnHost.network_path_generation` is independent from sleep
  `recovery_epoch` and all media/session epochs. A terminal Host start begins a
  fresh product path-observation lifetime at generation zero.
- Zero, duplicate, stale, future, and exhausted generations return the new
  stable `RDN_HOST_ERR_STALE_GENERATION (-27)` without changing Host state.
- Runtime join/start failures fail closed as Host `error`, registration
  `degraded`, and sleep recovery still `running`, with one of two sanitized
  registration diagnostics.
- The restart body contains no identity/config setter, media/session
  bind/unbind, password mutation, sleep/wakelock operation, or
  connection/codec/display epoch mutation.
- The built-core lifecycle performs two real registration runtime
  stop/join/start cycles and confirms the same `hostInstanceId`, stable
  `localId`, recovery epoch zero, and recovery status `running` afterward.
- The all-or-nothing shim host surface now requires the new symbol; an older
  host core cannot be misreported as ABI v9-capable.

## Verification

- `cargo test --manifest-path Vendor/rustdesk/Cargo.toml --lib --features rdn-native-core,rdn-native-host rdn_host_bridge::tests`:
  32 tests, 0 failures.
- `cargo test --manifest-path Vendor/rustdesk/Cargo.toml --lib --features rdn-native-core,rdn-native-host`:
  147 tests, 0 failures.
- `Scripts/build-rust-core.sh`: succeeded; the published arm64 core exports
  `_rdn_host_recover_network_path` and reports Host ABI v9 through lifecycle
  tests.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test --filter HostBridgeContractTests`:
  3 tests, 0 failures.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test`:
  795 tests, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  26 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `rustfmt --edition 2021 --check` for the tracked Host bridge and
  `cc -fsyntax-only` for the shim: passed.
- Schema-2 network restart and path-trigger audits plus schema-8 sleep audit:
  no missing evidence.
- Canonical bridge/vendor mirror comparison, RustDesk and `hbb_common`
  reverse-apply checks, both nested `diff --check`, and root `git diff --check`:
  passed.

## Remaining boundary

The Swift client does not yet expose the network operation and no bounded
authoritative ready-convergence owner calls it. `HostAgentNetworkPathRecoveryTriggerOwner`
is still not constructed in the Host process and no `NWPathMonitor` exists in
product source. Therefore this step does not claim Wi-Fi/Ethernet/VPN switch
recovery, active-session survival, or Mini/MBP acceptance. No App or Agent was
installed, launched, registered, deployed, or pushed. Hermes, CI, dependencies,
databases, real network configuration, TCC/configuration, and secrets were
untouched.
