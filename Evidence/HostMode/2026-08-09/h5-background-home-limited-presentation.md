# H5.2g Background Home limited-session presentation

## Outcome

The fourth H5.2 implementation checkpoint is complete. Background Home now
presents the strict top-level active-Aqua boundary instead of deriving session
status only from the nested keyboard/mouse tuple. A locked, LoginWindow, or
off-console/Fast User Switching projection is shown as a limited and currently
unsupported remote session, with capture suspension and input unavailability
stated on the active-session card.

Limited Home state hides approval and all capability-mutation buttons. The
current active session and its exact disconnect action remain visible. A
coherent later `available + null` projection restores the ordinary session
presentation and capability controls.

## Contract implemented

- A typed CoreBridge presentation policy consumes both strict tuples: the
  top-level `sessionAvailability/sessionUnavailableReason` authority and the
  nested input availability/reason. It does not consult `CGSession` again.
- Cross-level contradictions fail closed. Top-level available cannot pair with
  nested `sessionUnavailable`; top-level limited requires nested
  `limited/sessionUnavailable` for an active session.
- The background Home projection carries only a validated active-session
  presentation plus a derived mutation-visibility flag. If an active session
  cannot be presented coherently, the complete Home projection becomes
  unavailable.
- Limited readiness explicitly says that lock screen, LoginWindow, or another
  user session is not supported. The active card explains that the current
  version cannot operate there and that capture and remote keyboard/mouse are
  paused.
- The final App renderer uses the derived mutation-visibility flag for all
  three capability buttons. They are hidden while limited; disconnect remains
  governed by the existing exact-route command policy.
- The in-process Host uses the same bounded unsupported wording, but its local
  Aqua authority and behavior are otherwise unchanged.

## Verification

- Focused lifecycle/background Home/readiness/command/activation tests:
  45 passed, 0 failed.
- Fresh `swift test`: 832 passed, 4 conditional built-core tests skipped,
  0 failed.
- Fresh built-core
  `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`:
  832 passed, 0 skipped, 0 failed; the arm64 dylib passed strict code-signature
  verification.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  28 passed, 0 failed.
- Session audit schema 5 reports
  `detailed-home-limited-presentation-implemented` with no missing evidence.
- `swift build -c release --arch arm64`: succeeded.
- Canonical RustDesk and `hbb_common` patches passed reverse-apply checks; both
  tracked bridge mirrors match their Vendor copies byte-for-byte; nested and
  root `diff --check` checks passed.

## Remaining boundary

- Installed-build lock/unlock, LoginWindow, no-user-login, Fast User Switching,
  TCC continuity, fresh media epochs, and zero input/media leakage still need
  the real-Mac acceptance matrix.
- Same-session recovery revalidation and fresh media-epoch ownership should be
  audited as the next automatic H5.2 checkpoint before that acceptance.
- Secure Input remains a separate capability decision.

No App/Agent was installed, launched, registered, or deployed. No Hermes,
server key, CI, dependency, database, real TCC state, or user configuration was
changed.
