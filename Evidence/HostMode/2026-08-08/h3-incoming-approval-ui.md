# H3.2b3 snapshot-authoritative incoming approval UI

Date: 2026-08-08

## Outcome

FarPane now exposes the native pending-approval broker through a recoverable local prompt in the Host card. The prompt and every local action are reconciled against the latest authoritative Host snapshot rather than an event-owned UI state.

## UI and decision contract

- `HostSnapshot.pendingApproval` is the only request-state authority; Host events only cause the existing snapshot refresh path to run.
- The prompt marks the remote name, ID and platform as untrusted claims. It displays only the strict decoded capability allowlist, bounded transport classification and a presentation-only wall-clock countdown.
- The canonical connection ID is retained for the button callback but is not exposed as an additional UI/logging surface.
- A new connection ID requests macOS user attention once and brings the existing FarPane window forward. Repeated 500 ms snapshot polls do not repeat the notification.
- Approve/reject accepts only the exact current snapshot ID and only one in-flight click. Stale IDs and duplicate clicks are ignored before entering the Host command API.
- The App does not optimistically remove the prompt or report authorization success. Rust owns the deadline and single-final decision; a subsequent snapshot clears or replaces the prompt.
- Stable not-found/finalized/expired races use bounded product text. An unknown command failure becomes retryable only after a fresh snapshot still proves the same request pending.
- Host start/stop resets the local gate. Reconstructing `HomeView` does not reset Host state and therefore restores an existing request from the snapshot.

## Verification

Fresh checks on the Mac mini:

- `CoreBridgeContractTests`: 18 passed and 1 built-core conditional skip; the new decision-gate test covers notification dedupe, stale ID, duplicate click, in-flight preservation, snapshot dismissal and reset.
- Full Swift package with `Build/CoreBridge/arm64/liblibrustdesk.dylib`: 128 passed, 0 failed.
- Script tests: 20 passed, 0 failed.
- `swift build -c release --arch arm64`: passed.
- `rustfmt --check`, canonical Host bridge mirror, vendor `diff --check`, and both reverse patch checks: passed.
- `Scripts/preflight-host-mode-h1-golden.sh`: `H1_GOLDEN_PREFLIGHT_READY`; release executable/core UUIDs match the packaged App, stable non-CDHash signing passed, and the real ScreenCaptureKit to hardware H.264 test ran without skip.

Local arm64 delivery artifact:

```text
Build/HostMode-arm64-20260808124438/FarPane-arm64-20260808124438.zip
SHA-256: 148b1b737876df8dfcef1adaf948a2f02083588ef97815a6fc500d1148826d79
```

The ZIP was extracted and rechecked for build number `20260808124438`, arm64-only executable/core, strict deep signing and exact executable/core Mach-O UUIDs. It contains both the H3.2b3 prompt and the earlier H.265 frame-context crash fix. After confirming there was no post-launch HostMedia route, the same App was installed on the Mac mini; the prior bundle was moved to Trash, installed executable equality was verified, and the new process launched successfully. Deployment is not treated as manual approval or media acceptance evidence.

## Open evidence

This automatic step does not prove the end-to-end UI against a real controller. The new arm64 package still requires Mini/MBP checks for approve, reject, 30-second expiry, prompt recovery after App UI reconstruction, and a normal post-session return to ready. The earlier H.265 frame-context fix also still requires a continuous run beyond the old roughly 162-second crash point.

`passwordAndLocalApproval` remains fail closed because pinned upstream has no safe AND-mode mapping. This step does not change Host ABI/schema, RustDesk protobuf/wire behavior, Hermes, CI, root dependencies, credentials, or server state.
