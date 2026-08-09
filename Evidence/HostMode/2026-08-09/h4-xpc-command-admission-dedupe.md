# H4.3f2 Boot-bound command admission and dedupe authority

## Outcome

- Added a thread-safe, in-memory command reservation and result-replay authority bound to one validated Host instance and Agent boot identity.
- A fresh request ID can retry the same command ID and semantic payload without creating a second execution reservation.
- Queue acknowledgement is impossible before the future queue owner marks the exact reservation queued.

## Key evidence

- The dedupe fingerprint contains command name plus exact connection ID; request ID and send time are intentionally excluded from retry identity.
- First admission returns one exact reservation. Same-command concurrency before queueing returns `pendingQueue`; after `markQueued` it returns `alreadyQueued`.
- A typed final result is retained and replayed for later retries. Identical duplicate completion is idempotent; result-before-queued or conflicting final results terminally invalidate and clear the authority.
- Product capacity is 256 entries with a tested 1...1024 configuration range. Only the oldest completed result may be evicted; reserved and queued entries are never removed to make room.
- Capacity exhaustion with only in-flight work rejects new commands. Eviction is explicit evidence that an older command has left the bounded dedupe window.
- Foreign Host/boot requests, conflicting payloads and unknown results do not consume or replace valid entries.
- The authority has no XPC selector, execution queue, HostCore client, Core callback, external persistence or UI dependency.

## TDD evidence

- RED: the focused target failed to compile because the admission authority, reservation, outcomes, rejection reasons and snapshot types did not exist.
- GREEN: fourteen focused tests cover queue-before-ack, cancellation, result replay, fresh-request retry, conflicts, foreign identity, capacity, eviction, invalidation and 64-way concurrency.

## Verification

- `swift test --filter 'HostAgentXPC(CommandAdmissionAuthority|WireCommand)Tests'`: 21 tests, 0 failures.
- `swift test`: 638 tests, 4 skipped, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: clean.

## Remaining boundary

- No request handler currently decodes command Data, enqueues execution, emits/replays a command-result event or constructs the queued acknowledgement.
- There is no Objective-C selector, XPC listener integration, HostCore adapter, App command client or Home routing; background command availability remains false.
- H4.3f3 should compose the strict Data contract and authority through injected enqueue/result-emission seams before adding the product XPC selector.
- No App GUI, HostAgent process, SMAppService mutation, installation, deployment or real-device command was exercised.
