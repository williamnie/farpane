# H4.4a config isolation and concurrent-session authority audit

## Outcome

- Audited the complete product chain for §18 config isolation, canonical server projection, single-writer ownership and outbound Viewer coexistence.
- Classified each H4.4 requirement as proven automatically, code-ready but not accepted, or missing.
- Identified config-revision coherence as the next safe automatic boundary; no production code or external state changed.

## Requirement matrix

| Requirement | Authoritative current evidence | Status |
|---|---|---|
| Dedicated Host namespace before Rust config access | `HostAgentProcessRuntime.start` acquires bootstrap context before loading the Core; `HostAgentCoreRuntime.start` calls `setConfigRoot` before `start`; Rust `rdn_host_create` rejects calls before the one-shot root switch. Product constants are `FarPaneHost/io.rustdesknative`. | Proven by source and focused tests |
| Canonical App-owned server configuration | `DeviceCatalogStore/catalog-v1.json` is reloaded after save, projected without credentials, and atomically published as strict `bootstrap-v1.json`. Equal content is idempotent; server/build changes monotonically advance revision; rollback and same-revision mutation fail closed. | Proven by source and focused tests |
| Agent read-only startup input | Agent preflight reads only the fixed private projection and requires the exact installed build ID before acquiring the runtime lease or touching HostCore. | Proven by source and focused tests |
| Host single writer across upgrade overlap | Process-lifetime nonblocking exclusive `flock` is held by the bootstrap context. Its strict record contains only canonical boot ID, build ID and config revision; the second process fails without rewriting the live record. | Proven by source and focused tests |
| Host/Viewer process and filesystem isolation | Background Host runs in `--host-agent`; its process-local Rust globals are switched to `FarPaneHost`. The App Viewer stays in the App process and never receives that Host root switch. `startProductConnection` only stops retained App-local legacy Host state and does not unregister or cancel the background Agent. | Code-ready; no real concurrent-session evidence |
| Running Agent uses the current canonical revision | Bootstrap revision is consumed only at process start and retained in the lease. XPC peer/projection carries build/boot/Host identity but no config revision, and App readiness does not compare the current bootstrap against the live lease. | Missing; stale Agent can be presented ready after server revision changes |
| Versioned Host migration with old-config preservation | The bootstrap document has schema v1 and safe atomic publication, but the isolated Rust Host store has no separate Host migration/version authority. `rdn_host_start` writes server options through upstream `Config::set_option` before reading identity. | Not proven |
| Identity/server/password/UI storage separation | UI catalog and Agent bootstrap are separate from the Host root. Inside the isolated upstream Host root, identity, server options and permanent-password storage still use pinned RustDesk configuration authorities rather than independent FarPane migration stores. | Partial; security behavior is covered by H3, §18 storage separation is not complete evidence |
| V1 dual-active matrix and stable Host ID | No saved evidence covers Host-ready→outbound Viewer, incoming during Viewer, Viewer start/stop during active Host, simultaneous recovery, App restart with unchanged Host ID, or split Viewer/Agent/WindowServer/media resource budgets. | Manual/live evidence missing |

## Key evidence

- `HostAgentBootstrapProductIntegration` reloads the saved catalog; an unsaved in-memory server mutation cannot enter Agent input.
- `HostAgentBootstrapConfigurationPublisher` uses a private publication lock, temporary regular file, full write, file `fsync`, atomic `renameat` and directory `fsync`.
- `HostAgentSingleWriterLease` validates owner, permissions, file type and link count, and treats the live `flock` rather than file presence as ownership authority.
- `HostAgentProcessRuntime` retains the bootstrap context for the entire owned Core lifetime; teardown stops Core before releasing its lease owner.
- Rust config-root switching is process-local and precedes `Config::set_option`, `Config::get_id` and Rendezvous startup.
- The only App-side Viewer quiescence gate references `hostRuntimeActive`, `hostClient` and `hostRuntimeQuiescenceConfirmed`, which are legacy in-process Host evidence. The background activation/registration owner is not stopped on Viewer launch.
- Repository search finds `configRevision` in bootstrap/lease/App publication, but not in CoreBridge XPC handshake, snapshot, event, projection or background readiness types.

## Verification

- Focused bootstrap/publication/lease/config-root/owned-runtime/background-routing suite: 56 tests, 0 failures.
- Source audit covered §18, §20.2, §20.3, the bootstrap publisher/reader/context/lease, HostAgent process runtime, Rust config-root/start path, App Host ownership routing and Viewer launch.
- `git diff --check` will be rerun before final staging.

## Next automatic boundary

H4.4b should be a read-only coherence gate, not a service mutation:

1. securely observe the fixed live lease record without treating file presence as liveness;
2. bind its build/boot identity to the already authenticated live XPC peer;
3. compare its config revision with the current strict bootstrap projection;
4. withdraw background ready and command availability on missing, malformed, foreign or stale evidence;
5. do not restart, unregister or rewrite Agent/config state.

This can be implemented without changing XPC wire schema, Host ABI, Rust, Hermes, ServiceManagement, root configuration or dependencies. Automatic restart/update policy remains a separate architecture decision.

## Remaining manual boundary

- The five dual-session/recovery scenarios and stable Host ID require installed App/Agent processes and two-machine interaction.
- Combined performance must report Viewer, HostAgent, WindowServer and media processes separately.
- No local product config, identity, password, lease or server-key file was read during this audit.
- Nothing was installed, launched, registered, deployed or pushed.
