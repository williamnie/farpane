# Third-party notices

## RustDesk Core 1.4.9

The Phase 2/3 connection, session and input bridge is a modified derivative of RustDesk
1.4.9 at commit `6c578292e8ebbbec708b76986ba8c4bc7c509747`.
RustDesk is licensed under AGPL-3.0. FarPane uses the same license; its full
text is preserved in the repository root `LICENSE` file.

Tracked modifications are isolated in:

- `CoreBridge/RustDeskPatch/upstream-1.4.9.patch`
- `CoreBridge/RustDeskPatch/rdn_bridge.rs`
- `CoreBridge/RustDeskPatch/rdn_host_bridge.rs`
- `CoreBridge/include/rustdesk_native.h`
- `CoreBridge/Shim/rdn_shim.c`

The changes add the `rdn-native-core` feature, a narrow C ABI, an encoded
H264/H265 packet callback before RustDesk's decoder, H265-only negotiation for
this viewer, sanitized state/quality callbacks, decoder recovery, and a
non-persisted viewer session. Phase 3 adds a narrow semantic pointer/keyboard
ABI and delegates actual input message construction to the pinned RustDesk
session. Clipboard and audio remain disabled. RustDesk continues to own
connection, authentication, encryption and protocol handling.

Host Mode additionally introduces the `rdn-native-host` feature and
`rdn_host_bridge.rs`: a separate `rdn_host_*` Host Control C ABI (versioned
JSON commands/events/snapshots, opaque handle lifecycle, early config-root
isolation via APP_NAME/ORG, temporary password handling) and Host Media ABI
(native encoder capabilities, bounded encoded-access-unit injection and
encoder-state reporting). The feature-gated native producer in
`video_service.rs` wraps validated H.264/H.265 packets in the existing
`VideoFrame` service path; subscriber handling, QoS, refresh control,
encryption and Direct/Relay writers remain RustDesk-owned. Without the feature
the upstream behavior is unchanged; with it, host and viewer cores stay
mutually exclusive in one process.

Source: <https://github.com/rustdesk/rustdesk/tree/6c578292e8ebbbec708b76986ba8c4bc7c509747>

RustDesk PR #15682 at fixed head
`07c14cacf026d6585d3d78e3d9477c1f059de0da` was reviewed only to understand
client/session and codec boundaries. The project does not depend on or copy
that unmerged branch.

The local build uses pinned vcpkg ports for libyuv, AOM, libvpx and Opus. The
distributable App bundles their port copyright/license files under
`Contents/Resources/ThirdPartyLicenses/`. Redistribution of a built Core must
retain those notices together with RustDesk's full AGPL source offer.
