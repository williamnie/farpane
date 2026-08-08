# H2.1.11a native Host sleep-assertion policy and typed system evidence

- 日期：2026-08-07
- 范围：authenticated inbound connection lifecycle → macOS keepawake policy → `pmset` PID/type samples → performance gate
- 网络：本步骤未连接 Hermes，未修改服务端
- 密钥：未读取、未输出、未写入

## Outcome

FarPane native Host now requests a bounded user-idle system-sleep assertion only while at least one authenticated remote screen connection exists. File-transfer, port-forward and other non-screen authenticated scopes do not own this assertion. Native Host always requests `display=false`, so an active remote session does not force the Mac's physical display to remain lit.

Host startup installs the canonical `keep-awake-during-incoming-sessions=Y` setting inside the already isolated Host config root. The existing authenticated-connection RAII lifecycle remains the owner: the first eligible session creates the assertion and the last eligible session releases it. Explicit system sleep remains allowed because the existing macOS `WakeLock` continues to use `idle=true, sleep=false`.

The system sampler now records the total assertion count plus exact `PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep` counts for the supplied Host PID. System evidence and run-summary schemas advance additively to version 2. Active 1080p/4K performance validation requires at least one user-idle assertion in every sample, zero display-sleep assertions in every sample, and consistent typed/total counts.

No Host C ABI, route telemetry schema v7, Rust wire protocol, dependency, root configuration or Hermes behavior changed.

## Key evidence

- `incoming_wakelock_display` is a pure policy boundary. In native Host mode it returns `Some(false)` only for `remote_count > 0`; disabled policy or non-screen-only connections return `None`.
- The lazy wakelock thread pins whether it was created for native Host. Host shutdown therefore cannot briefly fall back to the upstream display-on policy after media unbind while connection teardown is still running.
- The non-native path preserves upstream behavior: any authenticated connection may hold the idle assertion, and a remote connection may additionally request the display assertion.
- The pinned `keepawake-rs` macOS backend maps `idle=true` to `PreventUserIdleSystemSleep`, `display=true` to `PreventUserIdleDisplaySleep`, and `sleep=true` to `PreventSystemSleep`; FarPane native Host never requests the latter two.
- `pmset -g assertions` is sampled once per interval, then filtered by exact `pid <Host PID>` and assertion type. No process name guessing or peer/server identity is recorded.

## Fresh verification

1. Focused Rust test filter `wakelock`: 2 passed, 0 failed.
2. Full Rust library suite with `rdn-native-core,rdn-native-host`: 96 passed, 0 failed.
3. Production arm64 Rust core build completed; the dylib is Mach-O arm64 and all existing Host/Viewer ABI symbol gates passed.
4. `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`: 100 passed, 0 failed, including full Host lifecycle and real H.264/HEVC hardware paths.
5. Real one-second sampler smoke against an explicitly allowed non-FarPane PID produced exactly 27 CSV columns, system schema v2, and typed assertion fields. Its zero assertion values describe that smoke process only and are not Host evidence.
6. Controlled active-route fixture with user-idle count 1 and display count 0 produced a schema-v2 `status=pass` summary. A second fixture with display count 1 exited 1, preserved `status=fail`, and reported the display-sleep assertion violation.
7. Sampler/runner `zsh -n`, validator `py_compile`, upstream patch reverse-check, canonical/vendor bridge byte comparison and repository whitespace check passed.
8. `swift build -c release` completed. `Build/FarPane-arm64-h2-sleep-assertion-preview.app` and `.zip` contain arm64 executable/core payloads; the app and a freshly extracted zip copy both pass strict deep signature verification with the existing stable development identity.

## Boundary

Deterministic policy tests and typed sampler contracts do not prove the Mac mini actually held and released the assertion during the earlier real FarPane session. That requires a new build on the mini plus active-session and post-disconnect/Host-ready sampling.

The existing H2 performance runner covers active 1080p/4K sessions only. A separate lifecycle scenario must prove Host-ready with no viewer has zero typed assertions, active remote screen has user-idle ≥ 1 and display = 0, and disconnect returns both to zero without a leak. Sleep/wake recovery itself remains H5.

## Next step

Add an H2.1.11b assertion-lifecycle runner that samples Host-ready → active route → disconnected-ready as explicit phases, preserves each phase as evidence, and fails closed on a missing assertion or post-session leak. Its real Mac mini execution remains a manual two-machine gate.
