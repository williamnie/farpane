# H5.3s exact two-PID combined-role sampler

## Outcome

- Added `Scripts/sample-farpane-host-combined-role.py` for the two §15.2 item 10 scenarios only: `host-ready-viewer` and `host-viewer-dual`.
- The sampler records HostAgent and Viewer as two exact, distinct process roles and reports their individual and combined process resources once per second.
- The sampler remains evidence collection only. It explicitly leaves Host runtime-state binding, Viewer streaming-report binding, the combined threshold and §15.2 item 10 completion false.

## Role and build authority

- The caller must pass `HOST_AGENT_PID` and `VIEWER_PID`; equal PIDs fail before sampling.
- `proc_pidpath` resolves the live executable for each exact PID.
- `KERN_PROCARGS2` supplies bounded argv evidence. HostAgent must contain exactly one `--host-agent`; Viewer must contain none. Only a SHA-256 of argv and the role flag count are persisted, not the command line itself.
- Both roles must use the exact same executable path, executable SHA-256, bundle identifier, `CFBundleVersion` and short version.
- PID, executable path, process start marker, argv hash and role flag count are rechecked every second. Full executable and bundle identities are hashed again at the end, rejecting exit/restart, PID reuse, argument mutation or build replacement.

## Resource scope

The sampler targets one row per second and records an authoritative monotonic timestamp on every row; command overhead cannot be hidden as an assumed interval. Each CSV row contains:

- separate HostAgent and Viewer PID, CPU, RSS, thread count and `top` relative energy impact;
- HostAgent + Viewer combined process CPU, RSS, threads and relative energy;
- separately labelled global aggregates for `WindowServer`, `videotoolboxd` and `VTEncoderXPCService`;
- system CPU, memory-free percentage, thermal pressure, power source, and sleep-assertion counts for both exact FarPane PIDs.

Shared helper processes may start or exit during a run; they remain shared/global evidence and are never assigned to HostAgent or Viewer. `top` power is explicitly relative and not joules or physical whole-system energy.

## Safety and publication

- Acceptance runs require 600–1,800 seconds; smoke runs allow 1–60 seconds through `FARPANE_HOST_COMBINED_SAMPLE_MODE=smoke`.
- Output prefix must be absolute, in an existing operator-owned non-symlink and non-group/world-writable directory.
- The CSV, metadata and log refuse overwrite and publish as a hard-link triplet only after the requested monotonic window and end-identity checks complete.
- Metadata contains SHA-256 bindings for the CSV and log and never stores full argv.

## Remaining boundary

The split sampler alone cannot prove either scenario. H5.3t subsequently implemented a strict combined manifest validator that binds:

1. this system sample;
2. coherent App-side Host runtime-state evidence covering the same monotonic/UTC window;
3. a `rustdesk-live` Viewer report proving authenticated streaming and decoded/presented frames;
4. scenario-specific ready/no-route or dual-active Host state;
5. the defined individual and combined process CPU budget.

The next automatic boundary is pairing one passing acceptance result for each scenario in the same machine/build/macOS scope. Installed App/Agent two-machine execution, the five V1 concurrency/recovery cases and stable Host ID remain live acceptance work.
