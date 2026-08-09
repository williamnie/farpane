# H5.3ah Viewer automatic recovery composition

## Outcome

The App now keeps one logical Viewer evidence epoch across a bounded automatic
replacement of the Rust Core client. An established Viewer terminal edge no
longer immediately tears down the product session. Instead the App schedules
up to three replacement attempts at 500, 1,500 and 3,000 milliseconds. Only a
real `.streaming` callback from the exact current replacement client can
produce the same-epoch `recoveredStreaming` evidence edge.

This step implements the product recovery authority needed by the
`dualDisconnectRecover` scenario. It does not implement the five-scenario
manifest validator, generate an installed two-machine result or claim that the
V1 concurrency matrix passes.

## Recovery authority

`ViewerAutomaticRecoveryOwner` owns one positive logical session epoch and a
strict state machine for initial streaming, waiting, replacement connecting,
recovered streaming, exhaustion and cancellation. Initial streaming is not
classified as recovery. A duplicate or stale terminal callback while waiting
is ignored. Each replacement attempt has an exact generation and attempt
number; three retryable start failures exhaust the fixed product delay list,
while an unavailable credential or invalid product scope terminates without
further network attempts.

The App gives every Core client a separate checked generation. State callbacks
are serialized onto the main queue and rejected unless their generation and
product attempt still match. The old client is disconnected, decoder state is
invalidated and a new Core client is constructed. Both the terminal callback
and the replacement streaming callback continue to use the original evidence
session epoch. Thus neither starting a replacement nor displaying a reconnect
message can create recovery evidence.

User disconnect, Home teardown, startup failure and App termination cancel and
drain scheduled recovery before stopping lifecycle evidence and disconnecting
the Core client. Password/authentication failures remain terminal and retain
the existing password-prompt flow rather than entering transport recovery.

## Credential boundary

The App does not retain the interactive password in a new recovery property.
After authentication the existing pending password is still cleared. A
replacement attempt reads the password only from the existing per-device
Keychain item and clears its local String after the Core connect call. A
connection whose password was not saved cannot be automatically reconstructed;
it returns Home with an explicit message and requires the user to enter the
password again. Server key, peer ID, password and packet/media data are not
written to lifecycle evidence.

No Host/Media/XPC ABI, wire schema, Rust bridge, Hermes service, CI, dependency,
database, installed app, TCC permission or external configuration changed.

## Verification boundary

The rerunnable audits are:

```sh
python3 Scripts/audit-host-agent-xpc-process-identity-contract.py
python3 Scripts/audit-host-v1-concurrency-evidence.py
```

They report `viewer-automatic-recovery-composed`, no missing evidence or source
anchors, and `nextImplementationBoundary=five-scenario-concurrency-validator`.
The focused recovery/App composition suite covers exact initial/recovered
streaming classification, fixed backoff, retry exhaustion, unavailable
credentials, stale epochs, duplicate terminal callbacks, cancellation, Core
generation gating and teardown ordering.

Fresh verification passed with focused recovery/App composition tests 12/12,
focused audit tests 2/2, full Swift tests 895/895 with four expected built-core
conditional skips, full ScriptTests 97/97, arm64 Release build, Python
compilation and `git diff --check`. The main H5 audit reports 42/42 evidence
checks and 103/103 source anchors; the identity/recovery boundary audit reports
16/16 evidence checks and 26/26 source anchors.

## Remaining boundary

The next automatic step is the strict five-scenario concurrency manifest
validator. Real `dualDisconnectRecover` still requires an installed build,
saved Keychain credential and two-machine network interruption/recovery to
generate live evidence; all five ordered scenarios and App-restart continuity
remain a later manual execution checkpoint.
