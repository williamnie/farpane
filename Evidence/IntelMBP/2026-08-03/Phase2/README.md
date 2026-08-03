# Phase 2 Intel acceptance evidence — 2026-08-03

Phase 2 passed its real Hermes -> Mac mini -> Intel MacBook Pro acceptance on
this date. The authoritative run is `acceptance-1800s/`; `preflight-60s/` is the
strict same-build preflight, and `build/` preserves the final Intel build/test
outputs. `environment.txt` records both machines without connection secrets.

All artifacts are integrity-protected by the nested and root `SHA256SUMS`
files. No fixture or offline run is represented as live acceptance evidence.
