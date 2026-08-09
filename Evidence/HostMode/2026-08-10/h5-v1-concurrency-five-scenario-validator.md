# H5.3aj V1 five-scenario concurrency validator

## Outcome

`Scripts/validate-farpane-host-v1-concurrency.py` now validates the five
ordered §18/§20.3 Host/Viewer coexistence scenarios from installed-process
lifecycle JSONL. This step implements the validator and its fail-closed
publication contract; it does not create a synthetic passing result and does
not claim that the installed two-machine matrix has run.

## Input contract

The schema-v1 manifest contains exactly five scenarios in this order:

1. `hostReadyThenOutboundViewer`
2. `viewerThenInboundHost`
3. `activeHostViewerStartStop`
4. `dualDisconnectRecover`
5. `appRestartStableHostID`

The first four contain one App and one HostAgent lifecycle source. The restart
case contains two distinct App lifetimes plus one HostAgent lifetime. Every
source is a safe relative `.jsonl` path, unique by canonical path and device /
inode, and bound by SHA-256. Each lifecycle must use the exact schema, one
immutable process identity, contiguous sequence `1...n`, nondecreasing wall
time, strictly increasing boot-monotonic time, and terminal
`processStarted ... processTerminating` edges.

The manifest also binds one no-overwrite passing
`farpane-host-combined-role-pair` result. Its item-10 scope supplies the
machine model, architecture, macOS version, packaged build and executable
authority. The validator derives the lifecycle build digest from the bound
`buildIdentifier`, so a hand-entered lifecycle build cannot drift from the
resource result.

## Ordered proof

- Ready-first requires ready → authenticated Viewer streaming → a later ready
  reaffirmation.
- Viewer-first requires authenticated Viewer streaming before inbound-active
  Host observation.
- Active-Host start/stop requires active Host → Viewer start/stream/stop → a
  later active Host reaffirmation.
- Dual recovery requires both roles active, both independently disconnected,
  and both independently recovered; HostAgent must also show its own ordered
  disconnected/recovered transition.
- App restart requires two ordered, distinct App process-start identities
  while the same HostAgent process and Host scope span both lifetimes.

For every App Host observation, the full Host/Agent scope must equal the
HostAgent writer scope and the same Host state must already exist in the
HostAgent lifecycle. All five scenarios must preserve one Host-instance scope
and use unique scenario-correlation digests.

## Failure and publication boundary

Unknown or extra keys, Boolean-as-integer values, malformed timestamps,
transition-generation errors, lifecycle gaps, identity drift, scope drift,
role mismatch, reused files, symlinks, hardlinks, path escape, hash mismatch,
failed item-10 authority and existing output all fail closed. The CLI writes a
temporary complete result, fsyncs it and publishes with a hard-link no-replace
operation. Credentials, peer IDs, raw process-start tuples, server settings
and media payloads are not inputs or outputs.

## Verification

- Focused validator regression: 6/6.
- Focused validator + main audit: 7/7.
- Full ScriptTests: 103/103.
- Full Swift: 897/897, with four expected built-core conditional skips.
- arm64 Release build: pass.
- Python compilation and `git diff --check`: pass.
- Main audit: `five-scenario-concurrency-validator-implemented`, 43/43
  evidence checks and 111/111 source anchors.

The first fresh Swift run exposed one stale source-text assertion from H5.3ai:
the argument label and typed XPC field had been formatted onto separate lines,
while the test still expected one line. The test now checks both semantic
markers independently; its focused rerun and the subsequent full suite pass.

## Remaining boundary

No `*v1-concurrency-result*.json` is checked into `Evidence/HostMode`. The next
boundary is installed App/HostAgent and two-machine execution with real
lifecycle files and a real passing item-10 resource result. Until that happens,
`v1ConcurrencyMatrixComplete` is not claimed by repository audit evidence.
