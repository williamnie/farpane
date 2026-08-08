# H2.1.5 Host telemetry evidence export

> 历史说明：本步验证的是初始 schema version 1。H2.3.4 additive version 2 增加六类 drop ledger，H2.3.5 additive version 3 增加 raw-frame queue depth；见 `h2-drop-reasons.md` 与 `h2-raw-frame-handoff.md`。旧 v1/v2 文件无需也不会被覆盖迁移。

- Date: 2026-08-07 (Asia/Shanghai)
- Scope: one explicitly enabled Host media route-stop diagnostic snapshot
- Schema: `farpane-media-telemetry`, version 1

## Implemented boundary

- Default App execution performs no telemetry file I/O.
- `FARPANE_HOST_TELEMETRY_OUTPUT` must name an absolute `.json` file.
- The writer serializes a fixed aggregate-metric allowlist and never serializes display index, PID, peer/connection/Host instance ID, rendezvous server, public key, password, output path, raw/compressed frame data, dirty-rect coordinates, or error text.
- A complete same-directory temporary file is atomically published with a hard link. Existing or concurrently created destinations are rejected; the writer never truncates or replaces evidence.
- App start failure and synchronous route cancellation both capture a diagnostic snapshot without echoing the configured path in an error.

## Fresh focused verification

- The evidence test parsed the encoded JSON and checked schema name, schema version, evidence kind, exact aggregate sections and forbidden identity/credential/payload field names.
- Environment tests confirmed default-off behavior and rejection of relative or non-JSON paths.
- A real filesystem write produced parseable non-empty JSON; a second write was rejected and byte comparison proved the first artifact remained unchanged.
- The executable target compiled with the new opt-in start/stop integration.

## Limitation

This file records code-level and focused filesystem verification only. No real Mac mini Host route JSON was generated in this step, and no 10/30-minute performance threshold is claimed. The exported diagnostic snapshot must be paired with the system-side sampler, scenario notes and Instruments evidence during formal H2 acceptance.
