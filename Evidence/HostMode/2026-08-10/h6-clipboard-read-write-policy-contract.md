# H6.2b clipboard read/write policy contract

## Outcome

The Host capability contract can now represent clipboard read and write
permission independently without opening a clipboard data path.

The Rust-owned `NativeClipboardPolicy` has separate `remote_read` and
`remote_write` authorities. Its projection supports all four policy states:

```text
disabled      -> viewDisplay
read only     -> viewDisplay, readClipboard
write only    -> viewDisplay, writeClipboard
bidirectional -> viewDisplay, readClipboard, writeClipboard
```

Capability subset checks also compare the two directions independently. The
legacy upstream connection Boolean is deliberately adapted to a bidirectional
policy for now, so existing sessions keep their current behavior until the
directional connection gates are implemented.

Both direct Host snapshot decoding and the XPC snapshot projection now accept
read-only and write-only active sessions. They still require a unique bounded
allowlisted capability set containing `viewDisplay`, active capabilities must
remain a subset of initial capabilities, and the input availability tuple
continues to fail closed.

## Contract/version boundary

No Host ABI or snapshot schema bump is required in this step. The existing
schema already names `readClipboard` and `writeClipboard` independently, and
pending approvals already accepted either name. This change removes an
incorrect active-session pair constraint; it does not add a field, command,
wire value or previously unknown capability.

## Closed runtime boundary

Clipboard remains disabled by the H6.2a startup authority:

```text
enable-clipboard=N
```

The current connection data plane still uses the single effective upstream
clipboard Boolean for both local subscription and incoming clipboard
admission. The current `disableClipboardForActiveSession` command also remains
an intentional bidirectional revoke. Therefore this step does not read or
write a pasteboard, advertise clipboard access, transfer a payload, or claim
that clipboard is usable.

## Remaining H6.2 work

- add separate connection gates for remote read and remote write;
- accept only bounded small UTF-8 text before enabling either direction;
- add independently scoped revoke commands and convergence checks;
- keep rich types, compressed payloads, files and images closed until their
  decompressed-size and transfer-lifecycle gates exist;
- replace the fixed listener interval with event-first observation and bounded
  dynamic-backoff fallback;
- clean temporary objects and promise providers at connection teardown.

The next bounded implementation is
`bounded-small-text-directional-gates`.

## Verification

- Full pinned Rust library tests with `rdn-native-host`: 152/152.
- Full Swift suite loading the freshly rebuilt arm64 Core: 897/897.
- Full script audit suite: 115/115.
- Clipboard policy audit: `clipboard-read-write-policy-contract`, 10/10
  evidence and 8/8 source anchors.
- Canonical and vendored Host bridge byte identity: pass.

## Operational boundary

No App/Core was installed or launched, no Host service was registered or
restarted, and no real configuration, pasteboard, credential, Hermes service
or network state was accessed. No replacement install package is emitted for
this representation-only boundary; a later package must include the bounded
directional data gates before users can enable or test clipboard transfer.
