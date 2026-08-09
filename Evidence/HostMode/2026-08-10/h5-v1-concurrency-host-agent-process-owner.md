# H5.3aa HostAgent process-lifetime coexistence evidence owner

## Outcome

- Reused the H5.3x/H5.3y best-effort process owner for the HostAgent role without changing the XPC wire contract.
- Added `configureHostAgent(expectedAgentBuildID:)`, which consumes the build ID already accepted by HostAgent entry preflight instead of rediscovering build authority from global bundle state.
- Connected one owner to the complete `HostAgentProcess.run` lifetime: `processStarted` is attempted before `HostAgentProcessRunner.run`, and `processTerminating` is attempted through a defer for every sanitized run result.
- Kept evidence default-off and non-authoritative for product outcome. Missing or malformed evidence configuration and append failure cannot alter HostAgent startup, termination or exit status.

## Role and identity boundary

The owner derives the exact current PID and macOS `PROC_PIDTBSDINFO` kernel start seconds/microseconds, hashes that raw start identity in memory, hashes the preflighted Agent build ID, and binds both to the HostAgent role plus the evidence-only scenario correlation. Raw identities and scenario text are never persisted.

The owner records to the process-local output selected by the existing `FARPANE_HOST_VIEWER_CONCURRENCY_OUTPUT` contract. App and HostAgent still require distinct output files; the writer remains no-overwrite and rejects unsafe paths.

Viewer transitions are accepted only when the configured role is `application`. Calling a Viewer API on a HostAgent owner returns no transition without appending, incrementing a failure, disabling the writer or affecting the product.

## Product lifecycle order

`HostAgentProcess.run` constructs and configures the owner before installing termination ingress or starting Core. A defer drains the evidence owner after `HostAgentProcessRunner.run` returns, covering successful stop, startup failure, stop failure and internal failure through the same evidence-only path. The return value from both configuration and termination is deliberately ignored.

## Remaining boundary

This step proves exact HostAgent process lifetime only. It does not emit Host ready/active/disconnected observations, add Agent PID/start identity to XPC, connect App Host observation, prove Viewer auto-recovery, create the five-scenario validator or claim a V1 matrix pass.

Historical update: H5.3ab subsequently retained the lease-bound boot/build/config identity through the running lifetime, H5.3ac normalized Host transitions, and H5.3ad connected the HostAgent continuous observation ingress. The App-visible versioned process-identity XPC contract remains open.

## Verification

Focused Swift owner/product composition tests passed 16/16. Full Swift tests passed 877/877 with 4 expected built-core environment skips; full ScriptTests passed 96/96; the arm64 Release build, Python compilation and `git diff --check` passed. The V1 audit reports `status=host-agent-process-owner-implemented`, 35/35 evidence checks and 67/67 source anchors.
