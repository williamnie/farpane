# H5.3r combined-role evidence authority audit

## Outcome

- Added a rerunnable, fail-closed audit for §15.2 item 10 without changing product behavior, Host ABI, wire schemas, Hermes, dependencies or external state.
- Froze two distinct 600-second live scenarios: background HostAgent ready while the App Viewer streams, and inbound Host media plus outbound Viewer streaming concurrently.
- Rejected the existing single-PID sampler and scenario labels as proof of split HostAgent/Viewer resource budgets.

## Key evidence

- `--host-agent` is the exact process-role selector. The normal App is the Viewer role and must not carry that flag.
- `startProductConnection` quiesces only retained legacy in-process Host state. It does not unregister or cancel the background HostAgent.
- App-side Host runtime-state evidence uses the coherent HostAgent XPC projection. It distinguishes ready/no inbound connection from authenticated active Host media.
- Viewer `PipelineMetrics` records the `rustdesk-live` source, state transitions, decoded/presented frames, process CPU and resident memory, and writes a JSON report.
- The current system sampler accepts `host-ready-viewer` and `host-viewer-dual`, but accepts only one `HOST_PID`, emits no Viewer columns and hard-codes `combined-host-agent-native-app`.
- `WindowServer`, `videotoolboxd` and `VTEncoderXPCService` are collected by global process-name aggregation. They are shared system scope and cannot be assigned to either FarPane role.

## Frozen target contract

Both required runs must provide at least 600 seconds of full concurrent overlap, bound by UTC and monotonic windows and SHA-256 evidence hashes.

1. `host-ready-viewer`
   - exact HostAgent PID has `--host-agent`, is coherently ready, has zero authenticated inbound connections and no active Host media route;
   - exact distinct Viewer PID does not have `--host-agent` and proves authenticated live streaming with state transitions and decoded/presented frames.
2. `host-viewer-dual`
   - the same two role identities remain distinct and stable;
   - Host runtime state proves an authenticated inbound connection and active Host media while Viewer streaming evidence covers the same full window.

Per-second process evidence must report HostAgent and Viewer CPU, RSS, thread count and relative energy separately, then report their combined process budget. `WindowServer` and media helpers remain separately labelled shared/global scope. Inputs must be safe relative paths, non-symlinks, unique, no-overwrite and hash-bound.

## Verification boundary

The audit intentionally returns `checkpoint-required`. It does not claim §15.2 item 10 pass because:

- a two-PID sampler and combined manifest validator do not yet exist;
- the numeric combined-process threshold has not been defined;
- installed App/Agent and two-machine runs have not been executed;
- the five V1 concurrency/recovery cases and stable Host ID still need live evidence.

H5.3s subsequently implemented the split-role sampler with exact PID/argument/executable/build identity checks and shared-scope labelling. The audit now returns `split-sampler-implemented`. The next safe automatic step is the combined manifest validator; readiness and streaming still must come from their separate authoritative evidence, never process liveness.
