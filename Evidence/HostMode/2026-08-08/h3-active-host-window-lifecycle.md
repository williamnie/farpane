# H3 active Host window lifecycle

## Outcome

Mac mini build `20260808124438` did not crash. At 2026-08-08 13:00:41 +0800,
AppKit first closed the only FarPane window and then performed an approved,
clean application termination. LaunchServices recorded exit status 0, and no
FarPane diagnostic crash report was created. Because `applicationWillTerminate`
runs the normal Host shutdown path, the remote session was disconnected.

The product app previously returned `true` unconditionally from
`applicationShouldTerminateAfterLastWindowClosed`. It now derives this decision
from the in-process Host runtime authority: an active Host survives closing the
last product window, while a normal non-Host app session keeps the existing
terminate-after-close behavior. Reopening FarPane from the Dock orders the
retained product window back to the front. Explicit Quit still invokes the
existing ordered Host shutdown and cleanup path.

## Verification

- `swift test --filter HostApplicationLifecyclePolicyTests`: 2 passed.
- `swift test --quiet`: 130 executed, 126 passed, 4 built-core conditional tests
  skipped, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 20 passed.
- `swift build -c release --product RustDeskNative`: passed.
- `git diff --check`: passed.

## Remaining boundary

The installed build is unchanged, so close-window/reopen behavior still needs
one real Mini check in the next package. This step does not implement H4's
separate background HostAgent: an explicit Quit still stops the current H1-H3
in-process Host, as designed.
