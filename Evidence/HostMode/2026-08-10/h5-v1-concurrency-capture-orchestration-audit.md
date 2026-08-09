# H5.3ak installed V1 concurrency capture orchestration audit

## Outcome

Added `Scripts/audit-host-v1-concurrency-capture-orchestration.py` as a
rerunnable checkpoint before controlling the installed App and SMAppService
HostAgent for five-scenario evidence capture. The audit reports
`capture-orchestration-contract-required`; it does not launch, restart or stop
any process and does not create runtime evidence.

## Confirmed gap

The App and HostAgent both read:

- `FARPANE_HOST_VIEWER_CONCURRENCY_OUTPUT`
- `FARPANE_HOST_VIEWER_CONCURRENCY_SCENARIO`

The signed LaunchAgent plist intentionally has no evidence environment. The
App can be launched directly with its own output path, but an already managed
SMAppService Agent does not inherit that process-local environment. Therefore
a manifest builder alone cannot produce the required Agent lifecycle file.
Editing the bundled plist would invalidate the signed-asset contract, while a
user-domain `launchctl setenv` would leak the evidence variables to every
future launchd child in that context.

## Frozen orchestration contract

The next implementation must require explicit operator invocation and target
only `gui/<current-uid>/io.rustdesknative.viewer.host-agent`:

1. Verify that exact registered service before mutation.
2. Configure the service's next invocation only with `launchctl debug
   --environment` and the two fixed evidence keys.
3. Restart it once with `launchctl kickstart -k -p`, then verify the returned
   PID, installed executable identity and exactly one `--host-agent` argument.
4. Launch the installed App executable directly with the same scenario value
   and a distinct App JSONL path; do not depend on `open`/LaunchServices
   environment inheritance.
5. Stop only a pinned, revalidated PID with graceful termination and wait for
   the terminal lifecycle record before finalization.
6. Hash-bind the unique lifecycle files and the preexisting passing H5.3u
   item-10 result into the H5.3aj manifest and publish the validator result
   without replacement.

The first four cases require one App and one Agent file. App restart requires
two distinct App files while one Agent process spans both complete App
lifetimes. Scenario actions remain operator-driven; the harness must never
infer success from elapsed time or advance prompts automatically.

## Forbidden mutations

- No signed plist edit.
- No global `launchctl setenv`.
- No SMAppService unregister/register cycle.
- No ad-hoc HostAgent executable.
- No process-name kill or unverified PID signal.
- No credential, peer ID, server configuration or media payload capture.
- No pass from smoke data or incomplete process lifetimes.

## Local command evidence

The installed macOS `launchctl(1)` manual confirms that `debug` configures the
next service invocation and supports service-scoped `--environment`; those
debug properties are cleared after that invocation. The same local manual
states that `setenv` applies to all future launchd processes in the caller's
context, which is why it is forbidden here.

## Verification

- Focused audit test: 1/1.
- Full ScriptTests: 104/104.
- Audit evidence: 8/8 checks and 14/14 source anchors.
- Python compilation and `git diff --check`: pass.

## Remaining boundary

`Scripts/run-farpane-host-v1-concurrency-capture.py` is intentionally still
absent. The next automatic step is to implement that exact contract with
injected command runners and offline fixtures before any installed process is
touched. Real two-machine execution remains manual and no V1 matrix pass is
claimed.
