# H6.2f temporary clipboard object and promise-provider teardown contract

## Outcome

Native Host clipboard teardown now clears the process-local small-text payload
cache and shared clipboard context after the final service unsubscribe, local
legacy/write revocation, and exact active Remote lease teardown. If the dormant
`unix-file-copy-paste` feature is enabled later, the same hook also destroys
the global rich clipboard `ContextSend` owner.

The pinned macOS file-promise implementation now gives each provider an
explicit, one-way lifecycle. Apple's
[`pasteboardFinishedWithDataProvider:`](https://developer.apple.com/documentation/appkit/nspasteboarditemdataprovider/pasteboardfinishedwithdataprovider%28_%3A%29)
callback marks the provider finished when AppKit no longer needs it, whether
its promises were fulfilled or pasteboard ownership changed. A finished
provider cannot create another temporary file. Failed UTI fulfillment and a
closed provider channel remove the exclusively-created file immediately.

The context records the `NSPasteboard.changeCount` produced by its promised
item and clears that item only while the observed count still matches. This is
a best-effort ownership guard: clipboard content already known to be newer is
preserved. Stop/drop cancels the paste task, clears worker-visible observer
state, stops observation, closes the channels, removes unclaimed temporary
files, and joins provider/removal threads on final context destruction.

## Scope and compatibility

The active FarPane product feature set remains
`rdn-native-core,rdn-native-host`; it does not compile
`unix-file-copy-paste`. The rich provider changes are therefore a verified
prerequisite, not product enablement. H6.2a's `enable-clipboard=N` remains the
runtime authority, and no ABI, XPC schema, wire protocol, UI, root dependency,
Hermes service, CI or database boundary changed.

All focused provider regressions are pure lifecycle/change-count predicates or
use a unique local temporary fixture. They do not read or write the real
pasteboard.

## Verification

- Full pinned Rust suite with current product features
  `rdn-native-core,rdn-native-host`: 158/158.
- Pinned Rust library check with `rdn-native-core` and no Host feature: pass.
- Native Host integration with dormant `unix-file-copy-paste`: 7/7 relevant
  clipboard tests.
- Focused macOS provider/context tests with `unix-file-copy-paste`: 4/4.
- Full clipboard subcrate feature suite: 9 passed, 1 unrelated pinned baseline
  failure in untouched
  `platform::unix::local_file::file_list_test::test_parse_file_descriptors`
  (`""` versus `"."`). The focused touched paths and root integration pass.
- Fresh arm64 Release Rust Core build: pass.
- Full Swift suite loading the fresh Core: 898/898.
- Full ScriptTests suite: 120/120.
- Fresh arm64 Release Swift build: pass.
- H6.2f audit: `temporary-clipboard-objects-cleaned-on-teardown`, 14/14
  evidence and 15/15 source anchors.
- H6.2a through H6.2e compatibility audit tests: 6/6.
- Tracked RustDesk patch reproduces the nested regular-file worktree exactly;
  reverse apply, root/nested whitespace checks: pass.

## Remaining H6.2 work

- expose a bounded small-text clipboard API in the native Viewer without
  enabling rich payloads or file promises;
- add explicit product enablement only after both Host and Viewer paths share
  the bounded contract;
- keep rich payload transfer closed until its independent size, filename/UTI,
  transfer and cleanup boundaries are implemented;
- perform enabled two-machine ownership/teardown, latency and idle-CPU
  acceptance on physical Macs.

## Operational boundary

No App or Agent was installed, launched, registered or restarted. No real
configuration, pasteboard, credential, key, Hermes service or network state was
read or changed. No package was emitted, pushed or deployed.
