# GUI-only source update

This complete snapshot includes the updated canonical and prepared GUI, the unchanged core/media sources, Cargo vendor and native dependency source archives. No binary or compiler cache is included.

binary-build-receipt.json binds to the incremental GUI build and reused core. gui-update/ retains the actual GUI build recipe, logs and artifact receipt. The root source manifest records the original source parent and this candidate.

The existing full source-build entrypoint can consume this snapshot. This packaging operation did not rebuild FFmpeg, core or GUI and does not claim a fresh full build. Open license/source audit items remain open.
