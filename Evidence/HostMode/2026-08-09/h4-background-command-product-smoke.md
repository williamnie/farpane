# H4.3f15 product-composed background command smoke

## Outcome

- Added one product-composed CoreBridge smoke from a Home semantic action through anonymous XPC queued acknowledgement and typed terminal projection.
- Verified that terminal state freezes stale Home controls until an authoritative snapshot replacement restores only still-valid actions.
- Changed no production implementation or protocol surface.

## Key evidence

- The App side uses the real background activation owner, reconnect owner, session lifecycle, event polling owner, snapshot client, command intent arbitration and Home presentation/read-only policies.
- The Agent side uses the real snapshot session handler, strict XPC interface, command admission/service, snapshot authority and shared typed event journal.
- The only injected boundaries are an anonymous listener endpoint instead of the installed Mach service and a queue ticket body instead of future Core execution. The service still owns request decoding, admission, correlated queued response and post-reply execution ordering.
- The submitted Home action resolves to exact `disableInputForActiveSession` and `host-a:session-1`; the test never constructs a wire command directly.
- The `.ok` result enters `HostAgentEventState` through the command service, is fetched by the real polling loop and completes the exact retained command ID.
- A completed result leaves read-only actions empty on the old route. A normal `snapshotChanged` then forces the real client resnapshot path; the new projection removes keyboard/mouse capability, clears the stale result and exposes only disconnect.
- No legacy callback, direct projection-sink publication, direct Home mutation or fake queued/event response exists in the smoke.

## Verification

- `swift test --filter HostAgentBackgroundCommandProductSmokeTests`: 1 test, 0 failures.
- Related activation/Home/reconnect/session/command suite: 85 tests, 0 failures.
- `swift test`: 714 tests, 4 environment-gated skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: clean before final staging.

## Remaining boundary

- Anonymous XPC proves the real Data/owner chain but does not prove the installed Mach service, LaunchAgent registration, code-signing identity or ServiceManagement lifecycle.
- The execution ticket records the typed Core request; it does not start a real Rust Host command.
- Two-machine UI acceptance for approve/reject, all three capability revocations, disconnect and same-command retry remains manual evidence when the controller machine is available.
- H4.4 Host/Viewer config-root isolation and real dual-active-session acceptance remain separate work; the next automated step is a bounded authority/gap audit.
- No App/Agent was installed, launched or deployed, and nothing was pushed.
