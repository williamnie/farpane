# H5.1j registration/assertion Host ABI ownership audit

> Historical checkpoint note: at commit `8ac5c96` the tracked audit reported
> `contract-gap-confirmed` for ABI v7/schema v5. H5.1k advances the same
> executable audit to verify the implemented ABI v8/schema v6 contract; the
> conclusions below remain the design evidence that authorized that change.

## Outcome

The pinned Host runtime cannot reuse its public stop operation for sleep recovery. The current Host ABI is version 7 and its snapshot schema is version 5; neither exposes a sleep/recovery epoch. `rdn_host_stop` is terminal: it unbinds media and the active native session, joins the Rendezvous runtime, and rotates the temporary password.

The minimum next contract is frozen as Host ABI version 8 and snapshot schema version 6. This audit does not implement or advertise that contract.

## Authoritative ownership

- Rust `HostRuntime` owns the Rendezvous thread, its stop signal, mediator exit, join, online reset, and asynchronous registration convergence.
- The existing Swift composition's synchronous `resumeRegistration() -> Bool` cannot mean registration is ready. After wake it must wait for an authoritative snapshot for the exact recovery epoch.
- The authenticated-connection `AuthedConnID` RAII path owns RustDesk's `WAKELOCK_SENDER`. Native Host remote-session count selects the user-idle assertion while the Rust wakelock thread creates and drops the actual platform assertion.
- Swift must not create a second assertion. Sleep recovery must command the Rust owner and wait for an explicit drop acknowledgement.
- Terminal stop remains separate. Sleep must preserve identity, registration configuration, permanent-password material, temporary-password continuity, media/session ownership, and connection policy until their existing authorities close them.

## Frozen ABI v8 / snapshot v6 target

1. `rdn_host_begin_sleep(host, epoch)` accepts only a strictly newer non-exhausted epoch, immediately withdraws registration/availability, publishes `suspending`, and signals the Rendezvous mediator to exit. It does not unbind media/session, rotate passwords, or mutate identity/configuration.
2. `rdn_host_finish_sleep(host, epoch)` accepts only the active epoch, joins the registration runtime, commands the Rust wakelock owner to drop its assertion, and waits for the matching acknowledgement before publishing `suspended`.
3. `rdn_host_resume_after_wake(host, epoch)` accepts only that suspended epoch and restarts registration. Its success means accepted/pending, never ready.
4. Snapshot schema 6 carries `recoveryEpoch`, `recoveryStatus`, and `registrationStatus`. Available publication is permitted only after the same epoch reaches an authoritative registration-ready snapshot.
5. Wrong, stale, duplicate, future, or exhausted epochs fail closed without new side effects. Existing terminal stop behavior remains unchanged.

## Machine-readable audit

`Scripts/audit-host-sleep-recovery-contract.py` reads only tracked source and emits compact JSON. It checks:

- Rust and C header ABI baselines agree at version 7;
- snapshot schema is version 5;
- the three target sleep symbols are absent;
- current runtime exposes terminal stop but no suspend/resume path;
- terminal stop unbinds media/session and rotates the temporary password;
- registration refresh has no suspended recovery state;
- authenticated-connection RAII owns wakelock updates and no Host sleep acknowledgement exists;
- the executable composition still models registration resume and available publication synchronously.

The script exits non-zero if any pinned-source premise drifts, preventing the target contract from being applied to an unreviewed baseline.

## Verification

- `python3 Scripts/audit-host-sleep-recovery-contract.py`: `contract-gap-confirmed`; no missing evidence.
- `python3 -m unittest Tests.ScriptTests.test_host_sleep_recovery_contract_audit`: 1 test, 0 failures.
- `swift test`: 758 tests, 4 conditional skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 24 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- Canonical RustDesk and `hbb_common` patches passed reverse-apply checks; both tracked bridge mirrors matched their vendor copies byte-for-byte.
- `git diff --check`: passed before staging.

## Remaining boundary

- H5.1k must implement the Rust/header/shim side of ABI v8 and schema v6, including a bounded Rust-owned wakelock drop acknowledgement. This is a shared ABI checkpoint and requires built-core lifecycle/ABI verification.
- A later step must replace Swift's synchronous registration seam with exact-epoch asynchronous snapshot convergence before `HostAgentProcess` or AppKit sleep/wake notifications are wired.
- No real sleep/wake, network switch, TCC, assertion, registration, Mini/MBP, installation, launch, registration, deployment, or push was exercised in this audit.
