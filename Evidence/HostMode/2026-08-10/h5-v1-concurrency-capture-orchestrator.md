# H5.3al installed V1 concurrency capture orchestrator

## Outcome

Implemented `Scripts/run-farpane-host-v1-concurrency-capture.py` for the exact
operator-driven contract frozen in H5.3ak. The tool prepares and closes the
five installed App/HostAgent lifecycle captures, then hash-binds them to the
preexisting passing item-10 pair result and invokes the H5.3aj validator.

This step did not run the capture tool against an installed App. It did not
start, restart or stop FarPane/HostAgent and does not claim a passing V1
concurrency matrix.

## Commands and state machine

The CLI exposes four explicit actions:

```text
start MATRIX_ROOT SCENARIO
restart-app MATRIX_ROOT
finish MATRIX_ROOT SCENARIO
finalize MATRIX_ROOT ITEM10_PAIR_RESULT
```

`MATRIX_ROOT` must already be an absolute, operator-owned mode-0700 directory.
Each `start` creates one unique scenario directory, verifies the installed
`/Applications/FarPane.app` signature and executable identity, verifies the
exact registered `gui/<uid>/io.rustdesknative.viewer.host-agent` service, and
uses service-scoped `launchctl debug --environment` for only its next
invocation before `kickstart -k -p`. The returned Agent PID must resolve to the
same installed executable/build and exactly one `--host-agent` flag.

The App executable starts directly with the same scenario correlation value
and a different JSONL output. The restart scenario alone requires
`restart-app`, which closes the first pinned App lifetime and starts a second
one while preserving the same Agent lifetime. Scenario UI/network actions
remain manual; the tool does not advance them based on elapsed time.

`finish` signals only receipt-pinned identities after revalidating PID, process
start, executable/build and argument digest. It waits for process exit and the
role-correct terminal lifecycle record. Interrupted healthy cleanup can resume
as `finishing`; failed/restart cleanup becomes `aborted` and can never be
promoted to `completed`.

`finalize` first verifies all five completed receipts and bounded lifecycle
files. Only then does it publish a no-replace item-10 copy and manifest, invoke
the strict H5.3aj validator, and require an exact schema-v1 passing result.

## Fail-closed boundaries

- No signed LaunchAgent plist edits, global `launchctl setenv`, SMAppService
  unregister/register, ad-hoc Agent or process-name kill.
- App and Agent always have distinct output paths; restart has two App paths.
- Receipt files are operator-owned mode-0600 strict JSON; existing scenario,
  resource, manifest and result paths are never overwritten.
- Changed/reused PID identity is refused before signaling.
- Failed or incomplete capture cleanup is `aborted`, not `completed`.
- Incomplete receipts are rejected before the item-10 copy or manifest is
  published.
- The existing strict validator remains the only matrix pass authority.

## Verification

- Focused orchestrator + audit tests: 9/9.
- Full ScriptTests: 112/112.
- Orchestration audit: `capture-orchestrator-implemented`, 10/10 evidence and
  18/18 source anchors.
- Python compilation and `git diff --check`: pass.

## Remaining boundary

Installed two-machine execution is still open. It requires the operator to
perform each of the five real UI/network scenarios between `start` and
`finish`, use `restart-app` only for the restart case, then call `finalize`
with the passing H5.3u item-10 pair result. No synthetic lifecycle or passing
matrix result was generated here.
