# H2.3.6c cross-language saturation boundary audit

- 日期：2026-08-07
- 范围：same-run Rust queue saturation → Swift drop ledger/reset
- 网络：未连接或修改 Hermes
- 密钥：未读取、未输出、未写入

## Outcome

No truthful unattended same-run harness exists within the current public/test surface. The production Host Media ABI exports capability configuration and access-unit submission, but native route creation and dequeue ownership remain internal to RustDesk `video_service`. Without a real subscribed Viewer, Swift submissions therefore fail closed before they can fill the capacity-three route queue.

The Rust unit harness can create and drain the internal production route and proves ABI backpressure/state preservation. Swift tests separately prove stable error mapping, ledger accounting, encoder generation replacement, and H.264/HEVC replacement IDR. Joining those into one run would require at least one prohibited expansion: a test-only route begin/dequeue C ABI, a Cargo feature/root build change, or a real two-machine slow-consumer session.

## Key evidence

- Exported media symbols contain no native route begin/dequeue operation.
- `rdn_host_media_submit_access_unit` requires the current instance/connection/codec/display route epochs and rejects when no authoritative subscriber route exists.
- The existing built-core lifecycle test confirms no-subscriber submit returns bad state; it cannot manufacture queue saturation.
- Adding a synthetic Swift-only backpressure result would retest mapping but would not be cross-language production evidence.

## Decision

Keep H2.3.6c open and require a real FarPane Viewer slow-consumer/controlled-network run, unless the user later authorizes a narrowly scoped test-only ABI/feature design. No ABI, Cargo feature, root dependency, Hermes setting, or production behavior was changed during this audit.
