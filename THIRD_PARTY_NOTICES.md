# Third-party notices

## SlopDesk video pipeline reference

The Phase 1 VideoToolbox and Metal implementation was informed by the minimal
decode/render subset of SlopDesk at commit
`b081d3cc08c36a97b240219ea93b9cb408bad143`:

- `Sources/SlopDeskVideoClient/VideoDecoder.swift`
- `Sources/SlopDeskVideoClient/MetalVideoRenderer.swift`

Only the macOS 13-compatible video pipeline ideas are used. SlopDesk's network
protocol, UDP/FEC implementation, macOS 26 UI, third-party dependencies and the
rest of its workspace are not included. The original project is MIT licensed;
the license text is preserved in `LICENSES/SlopDesk-MIT.txt`.

Source: <https://github.com/aislopware/slop-desk/tree/b081d3cc08c36a97b240219ea93b9cb408bad143>

## RustDesk Core 1.4.9

The Phase 2/3 connection, session and input bridge is a modified derivative of RustDesk
1.4.9 at commit `6c578292e8ebbbec708b76986ba8c4bc7c509747`.
RustDesk is licensed under AGPL-3.0; the upstream license text is preserved in
`LICENSES/RustDesk-AGPL-3.0.txt`.

Tracked modifications are isolated in:

- `CoreBridge/RustDeskPatch/upstream-1.4.9.patch`
- `CoreBridge/RustDeskPatch/rdn_bridge.rs`
- `CoreBridge/include/rustdesk_native.h`
- `CoreBridge/Shim/rdn_shim.c`

The changes add the `rdn-native-core` feature, a narrow C ABI, an encoded
H264/H265 packet callback before RustDesk's decoder, H265-only negotiation for
this viewer, sanitized state/quality callbacks, decoder recovery, and a
non-persisted viewer session. Phase 3 adds a narrow semantic pointer/keyboard
ABI and delegates actual input message construction to the pinned RustDesk
session. Clipboard and audio remain disabled. RustDesk continues to own
connection, authentication, encryption and protocol handling.

Source: <https://github.com/rustdesk/rustdesk/tree/6c578292e8ebbbec708b76986ba8c4bc7c509747>

RustDesk PR #15682 at fixed head
`07c14cacf026d6585d3d78e3d9477c1f059de0da` was reviewed only to understand
client/session and codec boundaries. The project does not depend on or copy
that unmerged branch.

The local build uses pinned vcpkg ports for libyuv, AOM, libvpx and Opus.
Their copyright/license files remain available in the generated vcpkg tree;
redistribution of a built Core must include the corresponding notices together
with RustDesk's full AGPL source offer.
