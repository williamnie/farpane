# H5.3u item-10 combined-role pair validator

## Outcome

- Added `Scripts/validate-farpane-host-combined-role-pair.py` to aggregate exactly one passing `host-ready-viewer` acceptance result and one passing `host-viewer-dual` acceptance result.
- Promoted machine, architecture, macOS, bundle/build/version and executable SHA-256 scope from the strict H5.3t validator into each single-run result.
- A pair passes only when both runs are 600–1,800-second acceptance results from the same exact scope and still satisfy the frozen scenario, threshold, metric, source-summary and claim contracts.
- A passing pair may set `section15_2Item10Complete=true`, but always keeps `v1ConcurrencyRecoveryMatrixComplete=false` because the broader five-case V1 concurrency/recovery and stable Host ID matrix is a separate live gate.

## Pair input contract

The schema-v1 pair manifest has exactly two SHA-256-bound relative JSON references:

1. `hostReadyViewer` must contain a passing `host-ready-viewer` H5.3t acceptance result;
2. `hostViewerDual` must contain a passing `host-viewer-dual` H5.3t acceptance result.

The referenced files must remain below the manifest root, be bounded single-link regular files, use no symlink component and have distinct paths and file identities. Hash drift, path escape, duplicate/hard-linked inputs, malformed or non-finite JSON and output overwrite fail closed.

Each single-run result is rechecked instead of trusting its `status` field alone. The pair validator requires the exact schema keys, scenario-specific thresholds, 600–1,800 second duration, one sample per requested second, cadence and state/presentation gaps no greater than 2.5 seconds, role and combined CPU averages below the frozen ceilings, positive resource/frame counters, complete Host state coverage, every single-run proof claim true and the single-run item-10 claim still false.

## Same-scope authority

Both acceptance runs must match exactly on:

- machine model and architecture;
- macOS version;
- bundle identifier, build identifier and short version;
- executable SHA-256.

This prevents combining independently valid runs from different machines, app builds or operating-system scopes into one item-10 result.

## Verification boundary

Synthetic positive fixtures prove that the validator can emit a passing pair, and negative fixtures cover smoke/short/failed results, incomplete claims, scope drift, scenario/threshold/metric tampering, unsafe paths, hash drift, symlinks, hard links, malformed types and output overwrite.

No passing live pair artifact was generated or saved in the repository. Therefore this implementation does not claim that §15.2 item 10 has passed on installed Macs. The remaining live boundary is to execute both concurrent scenarios on the same installed build and then run this pair validator. The five V1 concurrency/recovery cases and stable Host ID evidence remain separately open.

Fresh verification completed with 15/15 focused single-run and pair-validator tests, 95/95 full ScriptTests, 856/856 Swift tests (4 expected built-core skips), an arm64 Release build, Python compilation and `git diff --check`. The combined-role authority audit reports `pair-validator-implemented`, 24/24 evidence checks and 41/41 source anchors.
