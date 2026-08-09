# H5.3t strict combined-role manifest validator

## Outcome

- Added `Scripts/validate-farpane-host-combined-role.py` for one bounded `host-ready-viewer` or `host-viewer-dual` run.
- Added schema-v1 Viewer report identity and presentation-window fields so the validator can bind the exact Viewer PID/build and continuous presentation to the system sampler's monotonic window.
- Defined initial individual and combined CPU gates from existing product targets; shared system helpers remain outside the FarPane process sum.
- A passing acceptance result completes one scenario evidence package only. The result always keeps `section15_2Item10Complete=false`; H5.3u now owns the only conditional pair-level item-10 completion claim.

## Five-source manifest

The strict manifest contains SHA-256-bound relative paths for exactly:

1. H5.3s system metadata;
2. H5.3s per-sample CSV;
3. H5.3s sampler log;
4. App-side Host runtime-state JSONL;
5. Viewer pipeline report.

All source paths must stay below the manifest directory, use the expected suffix, resolve without symlinks, be single-link bounded regular files and have unique file identities. The validator rejects path escape, duplicate/hard-linked sources, digest mismatch, non-finite JSON, malformed schemas and output overwrite.

## Exact overlap authority

- System CSV PIDs must match the HostAgent/Viewer roles in metadata. Per-row monotonic time, elapsed time, role CPU/RSS/threads, combined sums and assertions are checked; first/final edge gaps and every cadence gap are bounded to 2.5 seconds.
- Host runtime state must bracket the system monotonic window with no sequence gap or state gap above 2.5 seconds. UTC-to-monotonic clock offsets must agree with the system sampler.
- `host-ready-viewer` requires coherent Host ready/registration ready, zero authenticated inbound connections, no Host media route/pipeline and no Host user-idle/display sleep assertion throughout the covered window.
- `host-viewer-dual` requires coherent ready plus at least one authenticated inbound connection, active Host media route/pipeline, a Host user-idle assertion throughout and no display-sleep assertion.
- Viewer report schema v1 now carries process ID, bundle/build ID, UTC and monotonic measurement bounds, and first/last presentation monotonic times. It must match the sampled Viewer PID/build, contain the whole system window, authenticate before streaming, present/decode frames in order, use hardware decode and have no presentation gap above 2.5 seconds.

The older aggregate Viewer report cannot pass this validator because it lacks these binding fields. Adding them changes evidence output only; it does not change media, input, Host ABI, XPC or network behavior.

## Initial CPU gates

The gates are strict averages and exclude `WindowServer`/VideoToolbox shared scope:

| Scenario | HostAgent | Viewer | HostAgent + Viewer |
|---|---:|---:|---:|
| `host-ready-viewer` | `< 2%` | `< 60%` | `< 62%` |
| `host-viewer-dual` | `< 25%` | `< 60%` | `< 85%` |

The HostAgent values use §15.3's ready and 1080p30 initial targets. The Viewer ceiling preserves the existing Phase 3 acceptance gate. The combined ceiling is the exact sum of the two role ceilings; shared system resources are reported separately and never hidden in this sum.

## Output boundary

- `status=pass` means all five sources agree and the scenario semantics/budgets pass.
- `scenarioEvidenceComplete=true` additionally requires an acceptance run of at least 600 seconds.
- Smoke runs may pass validation but never complete scenario evidence.
- `section15_2Item10Complete` remains false at the individual-run layer because both scenario acceptance packages must be aggregated separately.

H5.3u subsequently implemented the item-10 pair validator. Real execution of both scenarios on the same installed machine/build/macOS scope remains the next item-10 checkpoint; the broader five-case V1 matrix remains separate.
