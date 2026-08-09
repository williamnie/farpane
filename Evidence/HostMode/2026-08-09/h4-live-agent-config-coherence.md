# H4.4b live Agent config-coherence gate

## Outcome

- Added a read-only product gate that correlates the current canonical Host bootstrap with the running Agent lease and authenticated live XPC identity.
- Withdrew background readiness, read-only runtime fields and every Home command path whenever that evidence is unavailable, stale or foreign.
- Kept restart, registration and configuration mutation outside this step.

## Key evidence

- `HostAgentRuntimeConfigurationObservationReader` opens the fixed private HostAgent directory once and reads both `bootstrap-v1.json` and `.host-agent-runtime-v1.lock` through that same directory descriptor.
- Bootstrap and lease readers require a current-user-owned private directory, fixed filenames, regular current-user-owned `0600` files, one link, bounded documents and strict schemas. Missing, symlink, loose, hard-linked, oversized and malformed evidence fails closed.
- The lease file is only supporting identity evidence. The App supplies liveness from the already authenticated `available` XPC projection and requires exact lease-to-peer build and canonical boot UUID equality.
- The App also requires the latest bootstrap publication state to be `ready` and its just-published revision to equal the securely re-read disk revision. A failed publication cannot silently reuse an older coherent-looking file.
- The coherence policy requires bootstrap and lease revisions plus build identity to agree. Only `.coherent` permits the raw activation projection to reach Home readiness, snapshot projection, read-only command presentation or final command routing.
- Home refresh and command dispatch both recompute the gate from fresh filesystem evidence. Stale configuration, identity mismatch or unreadable evidence removes ready/runtime/command capabilities and emits only a bounded product error.
- The reader never takes the single-writer lock, treats file presence as liveness, rewrites either document, restarts the Agent, changes registration or opens System Settings.

## Verification

- `swift test --filter HostAgentRuntimeConfigurationCoherenceTests`: 5 tests, 0 failures.
- ConnectionCatalog plus readiness/snapshot/command/App contract related suites: 104 tests, 1 environment-gated skip, 0 failures.
- `swift test`: 719 tests, 4 environment-gated skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: clean before scoped staging.

## Remaining boundary

- This gate intentionally does not choose an automatic Agent update/restart policy. A stale running Agent remains unavailable until the user explicitly cycles the Host background component or another authorized lifecycle replaces it.
- H4.4 still lacks a dedicated Host-store migration/version and old-config preservation authority.
- The five §18/§20.3 Host-ready plus outbound Viewer scenarios, App-restart Host ID stability and split Viewer/HostAgent/WindowServer/media resource budgets require installed processes and two-machine manual evidence.
- No real App/Agent was installed, launched or registered. No user configuration, Host identity, password, lease or server-key file was read during verification; nothing was deployed or pushed.
