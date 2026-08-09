# H5.3x App process-lifetime coexistence evidence owner

## Outcome

- Added one `HostViewerConcurrencyEvidenceProcessOwner` to the App process and configured it before `NSApplication.run()`.
- The owner writes exact `processStarted` and `processTerminating` edges through the H5.3w strict writer while remaining default-off and best-effort.
- No injected identity is available to product composition: the public product initializer has no arguments, while test-only authority injection remains internal to `VideoPipeline`.
- Upgraded the rerunnable V1 audit to `application-process-owner-implemented` without claiming Viewer/Host lifecycle composition, a five-scenario validator or a live V1 pass.

## Identity and configuration authority

When `FARPANE_HOST_VIEWER_CONCURRENCY_OUTPUT` is absent, configuration reaches `disabled` before reading PID, process start, bundle metadata or scenario configuration. Explicit evidence additionally requires `FARPANE_HOST_VIEWER_CONCURRENCY_SCENARIO`; the raw scenario is bounded and domain-hashed by H5.3w and never persisted.

The App process identity is derived only from:

- exact current `getpid()`;
- the matching macOS `PROC_PIDTBSDINFO` record, including kernel process-start seconds and microseconds;
- packaged `CFBundleVersion` from `Bundle.main`;
- the explicit evidence-only scenario correlation value.

The owner converts all three raw identities to the existing domain-separated SHA-256 fields before constructing an immutable `.application` writer. Invalid/missing process metadata, build metadata, scenario, output path, writer creation or first append moves only the evidence owner to `unavailable`; no error escapes into App startup.

## Product lifetime

HostAgent mode dispatch still exits before `AppDelegate` construction. The application path creates exactly one owner, records `processStarted` before installing/running the application delegate, and deliberately ignores the configuration result.

Both App-owned exit paths close evidence exactly once:

- startup failure records `processTerminating` before the existing `exit(2)`;
- `applicationWillTerminate` first completes existing product teardown, then records the terminal edge.

Concurrent or repeated termination cannot append a duplicate. A terminal clock/write failure increments a sanitized counter, releases the writer and still commits the owner to `terminated`; it cannot alter the App's exit status.

## Verification

- Focused owner tests: 6/6.
- Focused App composition contract tests: 2/2.
- Focused audit: 1/1; `application-process-owner-implemented`, 23/23 evidence checks and 40/40 source anchors.
- Full ScriptTests: 96/96.
- Full Swift tests: 871/871 with 4 expected built-core skips.
- arm64 Release build, Python compilation and `git diff --check`: passed.

## Remaining boundary

The App evidence file currently contains process edges only. No authoritative Viewer transition or Host observation is connected, HostAgent has no matching H5 writer owner, and the repository still contains no five-scenario validator or passing result. The next automatic boundary is App Viewer lifecycle composition with explicit session epoch/generation authority; installed App/Agent and two-machine execution remain later manual evidence.
