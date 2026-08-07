# H1a.3 Hermes registration evidence

- Date: 2026-08-07 (Asia/Shanghai)
- Host: arm64, macOS 15.7.7 (24G720)
- Branch baseline: `feature/hostMode` at `fa26727`
- RustDesk upstream: 1.4.9 at `6c578292e8ebbbec708b76986ba8c4bc7c509747`
- Core artifact SHA-256: `f1a296da585cd432fb70c9db187c3107a94633b7c646eb63cd5d8a384a9245c0`

## Secret handling

The live rendezvous address and hbbs public key were read from the existing local
RustDesk configuration and passed only through the child-process environment.
The repository diff and persisted test/App logs contain no server key, local
RustDesk ID, password, peer ID, or authentication payload. UI acceptance checked
only state/presence assertions and did not persist those values. The hbbs private
key was never read or copied.

Before the live test, the decoded public-key SHA-256 from the local client
configuration was compared with Hermes `data/id_ed25519.pub`; the digests
matched. Only the digest comparison result was observed.

## Build and contract verification

`./Scripts/build-rust-core.sh` completed successfully and produced an arm64
Mach-O dylib. The Host ABI v2 surface exported `abi_version`, `create`, `start`,
`stop`, `copy_snapshot`, and `destroy` together with the existing Viewer ABI.

`RDN_CORE_LIBRARY=... swift test` completed with 41 tests and 0 failures. The
offline Host lifecycle exercised an unreachable fixture server and proved:

- unregistered state remains `starting/pending`, never a false `ready`;
- server/public-key validation happens before acquiring the singleton slot;
- start owns a rendezvous runtime thread;
- stop/destroy terminates and joins the runtime;
- a second HostCore instance can start after teardown;
- the isolated local ID remains stable across full stop/destroy/create/start.

## Live Hermes verification

The focused `HostBridgeContractTests/testFullHostCoreLifecycle` run used the
existing local Hermes configuration and passed in 2.417 seconds (1 test,
0 failures). The test requires both registration attempts to reach authoritative
`registrationStatus=ready`, with a complete stop/destroy between them, and
asserts that the two non-empty local IDs are equal without printing either ID.

After the run, the throwaway `FarPaneHostTestsRoot` configuration directory was
absent, proving the live test did not retain its generated identity or server
configuration.

## Result

An isolated arm64 acceptance App was built from the release executable and Core
artifact with its own temporary bundle ID and catalog. The App used the existing
local public Hermes configuration without printing or persisting its values.
Accessibility-level assertions proved:

- product launch entered the Home UI with Host enabled and reached `ready`;
- the Host toggle, local-ID projection, and redacted temporary-password UI were present;
- one-shot reveal worked, explicit hide returned to redacted, and regenerate kept it redacted;
- disabling Host stopped it; re-enabling first showed registering and returned to `ready` within approximately 3 seconds;
- no startup or password-command error was shown.

The acceptance App process, isolated preferences domain, and temporary directory
were removed after the run. A fresh release build and the full 41-test suite both
completed successfully with 0 failures.

H1a.3 and the complete H1a exit path are satisfied: App launch starts HostCore,
Hermes registration reaches authoritative ready, stable identity survives full
HostCore teardown, and temporary passwords are not written to repository files
or persisted logs. Screen capture, media transport, authentication UI, and
remote input belong to later phases and are not claimed by this evidence.
