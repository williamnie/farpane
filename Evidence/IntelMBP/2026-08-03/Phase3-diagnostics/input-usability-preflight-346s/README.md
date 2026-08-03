# Phase 3 input-usability preflight (failed)

This is a preserved diagnostic run, not Phase 3 acceptance evidence.

- Host: Intel MacBook Pro, macOS 13.7.8 x86_64
- Link: real RustDesk 1.4.9 Core through the configured secure Hermes relay
- Peer: real Mac mini, 4096x2304 H.265
- Runtime: 346.386 seconds
- Control boundary: `control-ready` observed; 2,601 pointer moves, 20 balanced button events, 938 scroll events, 204 balanced key events, and zero Core rejections
- User-observed failures: no Chinese IME composition, very slow scrolling, ignored key repeat, and visible interaction-time stutter
- Corroborating diagnostics: the app log contains repeated AppKit assertions from reading `charactersIgnoringModifiers` on modifier-only events; active presentation fell to 21.297 FPS with renderer drops while interacting

The run was stopped early and excluded from formal acceptance. No credential, peer ID, server address, key material, committed text, or full input message is recorded here.
