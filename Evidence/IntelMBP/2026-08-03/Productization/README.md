# RustDesk Native Viewer productization composite evidence

This directory combines three real secure-relay runs of the same final installed
build. The 1800-second run proves daily input and stability. During that run the
remote display metadata changed from the retained 4096x2304 baseline to 3840x2160,
so the original fixed-resolution single-run gate stopped before evidence staging.
That failed gate is preserved explicitly in composite-validation.txt and is not
represented as a successful single-run 4096x2304 acceptance.

A focused final-build supplement proves current 3840x2160 decoding, toolbar full-screen
and HUD transitions, exclusive-keyboard automatic restoration and balanced input. An
earlier preflight of the identical final viewer/Core hashes proves the retained
4096x2304 path at at least 28 encoded and presented FPS. The existing Phase3 evidence
remains unchanged and independently covers a 30-minute 4096x2304 baseline.

All artifacts are sanitized. No fixture is represented as a real link, and no password,
token, peer identifier, server address or key material is retained.
