# H2.2.12 strict live-log analyzer

Date: 2026-08-08

## Outcome

The repository now has a strict offline analyzer for H2.2.11 per-route live JSONL. It turns the full uninterrupted timeline into machine-checkable stage, cadence and pressure summaries after the gesture has ended.

## Contract

Invocation:

```text
Scripts/analyze-farpane-host-media-live.py INPUT.jsonl [OUTPUT.json]
```

The validator fails closed on:

- wrong schema/version, missing fields or any field outside the explicit v1 allowlist;
- invalid JSON, non-finite numbers, unsupported enum values or inconsistent queue/pressure fields;
- sequence gaps, backwards monotonic/wall time, missing/duplicated/interior lifecycle events;
- more than 3,600 periodic samples or a log without periodic samples;
- replacement of an existing output artifact.

For a valid route it reports capture/encode/Rust-admission min/median/max, median absolute stage gaps, cadence/content/applied/current pressure distributions, cause counts, dirty-metadata and configuration-update counts, and contiguous regimes split whenever cadence/content/pressure/cause changes.

`performanceVerdict` is always `diagnostic-only`. A short live log can localize a pressure trigger or stage discontinuity but is not §15 acceptance evidence.

No App binary, Host ABI, wire protocol, Hermes service, dependency, CI, database or performance policy change.

## Verification

```text
python3 -m unittest Tests/ScriptTests/test_host_media_live_analyzer.py
result: 4 passed, 0 failed

python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'
result: 17 passed, 0 failed
```

The fixtures cover a valid two-regime route, stage alignment, pressure cause counts, sequence and lifecycle failure, unknown sensitive fields, NaN rejection, the periodic bound and atomic no-replace output.

## Remaining evidence

The first Mini JSONL passed this validator and selected H2.2.13 from production pressure-source evidence. Future builds should keep using the same artifact path so policy changes can be compared without copied point readings.
