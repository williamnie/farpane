# H5.1a Host runtime network reconnect backoff

## Outcome

The native Host rendezvous runtime no longer restarts its registration loop on a fixed one-second cadence after the existing RustDesk mediator exits. Each unsuccessful or short-lived connection now advances a Host-only exponential backoff from 250 ms, adds a bounded 0–25% time-based jitter, and caps the total delay at 5 seconds. A connection that remains alive for at least 30 seconds resets the next retry to the initial delay.

The retry wait polls the process-owned stop flag at intervals no longer than 50 ms. A normal Host stop therefore interrupts even a capped retry delay instead of blocking teardown for up to five seconds.

## Invariants

- Recovery reuses the same rendezvous server string, server instance and existing `Config` identity. It resets only online status and never calls an ID/config setter.
- Backoff runs only after `RendezvousMediator::start` returns and only while the same Host runtime remains active.
- Explicit Host stop still uses the upstream native stop signal first; a stopped runtime never schedules another mediator.
- The change is private to the feature-gated Host bridge. Host Control/Media ABI, event/snapshot schemas, shared `hbb_common`, Hermes and Viewer behavior are unchanged.

## Key evidence

- Deterministic Rust coverage proves maximum-jitter delays of `312, 625, 1250, 2500, 5000, 5000…` ms, the hard 5-second cap and reset to 250 ms after the stable-connection threshold.
- An async Rust test requests a five-second retry, raises the stop flag after 5 ms and proves the wait exits as stopped in under one second; the product poll slice is fixed at 50 ms.
- A Swift source-order contract proves connection lifetime measurement precedes mediator start, delay calculation follows mediator exit, the interruptible wait follows delay calculation, the old fixed one-second sleep is absent and the runtime body does not reset identity.

## Verification

- `cargo test --manifest-path Vendor/rustdesk/Cargo.toml --lib --features rdn-native-core,rdn-native-host rdn_host_bridge::tests`: 29 tests, 0 failures.
- `CoreBridgeContractTests/testHostRuntimeReconnectUsesBoundedBackoffWithoutIdentityReset`: 1 test, 0 failures.
- `./Scripts/build-rust-core.sh`: arm64 Release dylib rebuilt successfully.
- Built-core `HostBridgeContractTests/testFullHostCoreLifecycle`: 1 test, 0 failures.
- `swift test`: 722 tests, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- Swift arm64 Release build succeeded.

## Remaining boundary

- This is H5.1a, not completion of H5.1. It relies on real socket/mediator exit as the network-loss signal; explicit path-change observation and live Wi-Fi/Ethernet switching evidence remain.
- Sleep notification handling, pre-sleep media pause/flush, wake display/TCC revalidation and display-reconfiguration ownership are not implemented here.
- The bounded per-attempt delay is not the overall recovery window. Ending an active session after a product-defined maximum recovery duration remains a separate step.
- No real Host, App or Agent was launched, installed, registered or deployed; no real product config or secret was read, nothing was pushed, and Hermes/CI/dependencies/databases were untouched.
