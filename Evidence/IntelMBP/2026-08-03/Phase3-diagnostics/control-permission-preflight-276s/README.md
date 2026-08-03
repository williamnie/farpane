# Phase 3 control-permission preflight (failed)

This is a preserved diagnostic run, not Phase 3 acceptance evidence.

- Host: Intel MacBook Pro, macOS 13.7.8 x86_64
- Link: real RustDesk 1.4.9 Core through the configured secure Hermes relay
- Peer: real Mac mini, 4096x2304 H.265
- Runtime: 276.165 seconds
- Result: failed; 1,031 input events were rejected before entering the Rust Core input path
- Working UI checks: six fullscreen toggles and ten HUD toggles
- Root cause: the native bridge initialized `server_keyboard_enabled` to false, while the upstream protocol uses true as the default and only sends an explicit permission event when the peer disables control

The run was stopped early and excluded from formal acceptance. No credential, peer ID, server address, key material, or full input message is recorded here.
