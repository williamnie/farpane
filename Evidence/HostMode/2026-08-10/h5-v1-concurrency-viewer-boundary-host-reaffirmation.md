# H5.3ai Viewer-boundary Host reaffirmation

## Outcome

The App now records an exact coherent Host checkpoint immediately after a real
Viewer streaming edge and immediately after a Viewer stopped edge. These
observation-only checkpoints close the evidence gap for two ordered V1 cases:

- `hostReadyThenOutboundViewer` can prove the Host is still ready with zero
  inbound sessions after Viewer authentication/streaming;
- `activeHostViewerStartStop` can prove the inbound Host session is still
  active after the Viewer has stopped.

This is a prerequisite evidence seam, not the five-scenario validator. It does
not generate a live result or claim that the V1 matrix passes.

## Exact reaffirmation authority

`HostAgentApplicationConcurrencyObservationState` may reaffirm only its exact
latest coherent candidate. It retains the already-validated five-field XPC
peer identity, positive configuration revision and normalized ready-zero or
inbound-active state, but never retains a snapshot payload. If the latest
candidate is transport-unavailable, configuration-unavailable, foreign scope
or failed, reaffirmation emits nothing. A successful reaffirmation receives a
new contiguous App source generation without pretending that a new projection
sample arrived.

The lifecycle process owner has a dedicated App-only reaffirmation API. It
requires the supplied scope and normalized runtime state to match its exact
current Host session. Unlike ordinary semantic duplicates, this one checked
checkpoint is appended with the current evidence state and transition
generation. It cannot initialize Host state, change ready/active state, revive
disconnected evidence, change identity or bypass the normal transition
machine. Ordinary duplicates continue to advance only the watermark.

## Product ordering

On first or recovered Core `.streaming`, the App first commits the Viewer
`authenticatedStreaming` or `recoveredStreaming` record. Only if that append
succeeds does it reaffirm the current coherent Host observation. During Home
teardown, the App first cancels Viewer recovery, then commits Viewer `stopped`,
then reaffirms Host, and only afterwards disconnects Core and clears the UI.
Initial Home construction, startup failure without a committed Viewer epoch,
duplicate streaming, stale callbacks and evidence-disabled runs do not create
checkpoints.

No Host/Media/XPC ABI or wire schema, Rust, Hermes, CI, dependency, database,
installed app, TCC permission, credential or external configuration changed.

## Verification boundary

Focused state/process/App composition tests cover coherent reaffirmation,
unavailable-latest rejection, initial/mismatched-state rejection, ordinary
duplicate watermark behavior and exact Viewer-before-Host record ordering.
The rerunnable main audit reports
`status=viewer-boundary-host-reaffirmation-composed`, 43/43 evidence checks,
106/106 source anchors and
`nextImplementationBoundary=five-scenario-concurrency-validator`.

Fresh verification passed with focused state/process/App composition tests
23/23, focused audit 1/1, full Swift tests 897/897 with four expected built-core
conditional skips, full ScriptTests 97/97, arm64 Release build, Python
compilation and `git diff --check`.

## Remaining boundary

The next automatic step is the strict five-scenario concurrency validator.
Installed App/Agent two-machine execution must later supply the lifecycle,
machine/build and item-10 resource sources; no saved passing matrix result is
present in the repository.
