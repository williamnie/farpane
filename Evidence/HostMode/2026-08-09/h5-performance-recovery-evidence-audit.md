# H5.3g Recovery performance evidence checkpoint

## Outcome

Section 15.2 item 7 now has an executable source audit and a frozen fail-closed
evidence boundary. The product already owns real sleep/wake, network-path, and
display-reconfigure recovery chains, but the current performance artifacts do
not correlate those transitions with the required post-recovery scenario 3
runs. At this original checkpoint the audit reported `checkpoint-required`;
the subsequent H5.3h writer implementation advanced readback to
`writer-implemented`. H5.3i now advances it to `process-owner-implemented` by
adding the process-lifetime digest/writer authority. H5.3j advances current
readback to `sleep-wake-callback-implemented`: the exact sleep/wake acceptance
and successful convergence callback is connected. H5.3k advances current
readback to `network-callback-implemented`: exact network generation/epoch
acceptance and convergence are also connected, while display and real runs
remain open. None of these statuses claims a recovery or performance pass.

The next implementation must create a dedicated sanitized transition record
for each recovery kind and bind it to one fresh, passed, 600-second `1080p30`
run on the same machine, build, and Host scope. Scenario labels, generic
disconnects, route absence, media `reconfigure` drop counts, and unbound ready
snapshots are explicitly forbidden as substitutes.

## Key evidence

- Sleep/wake recovery publishes the exact recovery epoch first as
  `suspending`, then as authoritative `running + ready` after convergence.
- Network-path recovery preserves the exact path generation through the real
  restart operation and converges against the same recovery epoch and
  `running + ready` snapshot.
- Display reconfiguration remains owned by the pinned RustDesk monitor video
  service; a replacement route receives fresh connection and codec epochs.
- The sampler accepts a `recovery` label, but the performance validator has no
  recovery scenario contract and the base matrix explicitly leaves section
  15.2 item 7 uncovered.
- Runtime-state schema v2 exposes no recovery epoch/status, path generation,
  or display revision. Media telemetry intentionally omits route identity and
  exposes only an aggregate reconfigure-drop counter, so neither artifact can
  prove the transition kind or correlation by itself.

## Frozen target contract

- Transition schema v1 allows exactly `sleepWake`, `networkPath`, and
  `displayReconfigure`, with monotonic sequence, accepted/completed timestamps,
  status, sanitized Host/build scope, and authority-specific correlation.
- Sleep/wake binds the exact recovery epoch and running/ready convergence.
- Network path binds path generation, recovery epoch, and running/ready
  convergence.
- Display reconfigure binds pre/post display revision plus previous/replacement
  connection and codec epochs, so route freshness is directly comparable,
  without persisting raw display, peer, server, or credential identity.
- A manifest requires exactly three transition proofs and three passed
  `1080p30` summaries, each at least 600 seconds and ordered after its completed
  transition. Sources must be SHA-256 bound and path escape, symlink, duplicate,
  or overwrite attempts must fail closed.

## Verification

- Focused recovery evidence audit regression: 1 passed, 0 failed.
- The audit emitted schema
  `farpane-host-performance-recovery-evidence-audit` v1,
  `status=checkpoint-required`, 7/7 evidence checks true, 8/8 source locations
  present, and no missing evidence.
- This step changes only an audit script, its regression, this evidence record,
  and the design status. It does not change a product ABI or execute a recovery.

## Remaining boundary

- Connect the process-lifetime writer only to exact successful convergence
  callbacks for display reconfiguration; sleep/wake and network path are now
  connected by H5.3j/H5.3k.
- Implement the bounded recovery manifest validator and negative fixtures.
- On an installed Mac, execute all three recovery types and one fresh
  600-second scenario 3 run after each transition.
- Battery/thermal and combined Host/Viewer budgets remain separate section
  15.2 items 9 and 10.
- No App or Agent was installed, launched, registered, or deployed. Hermes,
  CI, dependencies, database, real TCC/configuration, and secrets were not
  changed; nothing was pushed.
