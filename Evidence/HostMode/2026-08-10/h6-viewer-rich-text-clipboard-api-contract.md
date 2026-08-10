# H6.2j3 Viewer rich-text clipboard API contract

Date: 2026-08-10

## Outcome

Viewer ABI v7 exposes a bounded semantic rich-text bundle without enabling the
product feature. Receive and send rich-text directions are independent and
default off. Existing bounded small text remains intact.

## Contract

- An atomic bundle contains optional plain UTF-8 text (64 KiB maximum), optional
  RTF (1 MiB maximum), and optional HTML (1 MiB maximum).
- At least one RTF or HTML representation is required. Incoming wire payloads
  accept one to three canonical entries and at most one of each format.
- Empty, duplicate, unknown, image/special, malformed-metadata, invalid UTF-8,
  NUL, oversized wire, and oversized decompressed representations fail closed.
- Incoming compressed data uses bounded decompression. Outgoing data is always
  canonical and uncompressed, using one `Clipboard` or one `MultiClipboards`.
- Receive admission checks active/authenticated/local-rich-receive/remote-
  clipboard permission before parsing or decompression and rechecks before the
  callback, closing the race with permission or lifecycle teardown.
- Send admission checks active/authenticated/local-rich-send/remote clipboard
  permission before handing a message to the existing RustDesk sender.
- Callback pointers are callback-scoped. Swift copies every non-null byte range
  synchronously, validates the bundle again, and uses the existing queued
  clipboard delivery gate so disconnect drops stale callbacks.

## Deliberate non-goals

- FarPane's Viewer connection configurations and `ViewerPasteboardOwner` do not
  enable or consume the rich API in this step.
- Native Host admission remains `InlineSmallText` only. This step does not add
  Host/Viewer rich transport ownership or alter the RustDesk protocol.
- No AppKit pasteboard access, image/file payload, Hermes change, installation,
  deployment, or push is performed.

## Verification

- Focused Rust rich clipboard contract: 5 passed, 0 failed, including a direct
  dynamic check that every pre-parse authority is required.
- Complete pinned Rust `rdn-native-core,rdn-native-host` library suite: 169
  passed, 0 failed.
- Fresh arm64 Release Core build exported
  `_rdn_client_send_clipboard_rich_text` and passed the required symbol gate.
- Focused Swift `CoreBridgeContractTests`: 43 passed, 0 failed with the fresh
  ABI v7 Core loaded.
- Complete Swift suite with the fresh ABI v7 Core: 917 passed, 0 failed.
- Complete ScriptTests suite: 127 passed, 0 failed.
- Viewer-only `rdn-native-core` Release check and Swift Release build passed.
- Canonical RustDesk patch reverse-check, canonical/vendor bridge equality, and
  `git diff --check` passed.
- Machine audit:
  `python3 Scripts/audit-viewer-clipboard-rich-text-api-contract.py`.

## Next boundary

`host-viewer-rich-text-transfer-wiring-contract`: connect the existing Host
bounded rich envelope and Viewer ABI v7 through explicit direction gates while
keeping AppKit product ownership disabled until a later step.
