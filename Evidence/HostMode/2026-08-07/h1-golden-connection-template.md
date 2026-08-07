# H1 FarPane Golden Connection evidence — PASS

- Date/time: 2026-08-07 18:xx Asia/Shanghai (user-reported live run)
- Host package: `HostMode-arm64-20260807183635`, build `20260807183635`
- Host executable SHA-256: `6e22cf90d6797ffe4f8f53bdff602bc26e978950285456d5a195fdfd9dbea922`
- Host preflight result: `H1_GOLDEN_PREFLIGHT_READY`
- FarPane controller version: existing/old build; exact version not recorded
- Controller OS/device: macOS / MacBook Pro
- Host OS/device: macOS / Mac mini
- Transport observed: Direct / Relay / Unknown
- Sensitive values redacted: yes

## Required observations

- [x] Host reached authoritative registration `ready` (required before the reported ID/password connection succeeded).
- [x] FarPane controller established an active session.
- [x] Rust writer dispatch is proven by the route-matched `refreshKeyframeDispatched` milestone, which is emitted only after a keyframe is sent to at least one subscriber.
- [x] Remote delivery and decoder acceptance are proven by the MBP FarPane rendering the live desktop; the exact transient `firstPacketAcknowledged` label was not observed before later refresh status replaced it.
- [x] FarPane controller displayed the remote desktop normally (explicit user report).
- [x] Controller recovery automatically requested Refresh and Host reported both “远端请求刷新，正在生成关键帧” and “刷新关键帧已发送”; the old FarPane build has no manual Refresh button.
- [x] The same controller session remained connected and the remote picture continued without reconnecting after Refresh recovery (explicit user confirmation).
- [x] Disconnect returned the Mac mini Host to “可被连接” (explicit user confirmation).

## Framing result

- Negotiated codec: HEVC compatibility path used by the old FarPane Viewer
- Accepted framing: 4-byte length-prefixed access units from the Host HEVC pipeline
- Startup IDR contained VPS/SPS/PPS: yes (Host encoder contract plus successful remote decode)
- Refresh IDR contained VPS/SPS/PPS: yes (`刷新关键帧已发送` is displayed only when the route-matched keyframe reports parameter sets)
- Provisional fixture promoted to FarPane-controller golden: no

## Verdict

Pass. FarPane → Hermes → FarPane Host authentication, subscription, HEVC hardware media path, Rust writer dispatch, remote rendering, automatic Refresh → IDR recovery without reconnecting, and teardown back to ready all passed on separate MacBook Pro/Mac mini machines. The exact transient ACK label was not observed, but successful remote decode is stronger downstream delivery evidence and the missing label is retained only as a telemetry/UI observation. H1/H1b/H1c exit conditions are satisfied; H.264 real-controller regression remains a later dual-codec compatibility check, not a blocker for this HEVC Golden Connection.
