# Phase 2 rapid reconnect profile-selection failure

After the successful 4K smoke, the chained acceptance launch exited before
connecting with sanitized Core error `-5`. Investigation proved that the
previous bridge initialization had allowed RustDesk to create a profile whose
name was the composite custom-server target rather than a plain peer ID. The
config wrapper then selected that newest composite profile, which the bridge
correctly rejected because it contained `@`.

The repair removes persisted latest-target mutation, restores the existing
plain peer profile as the native session's in-memory baseline, clears any
remembered password from that in-memory copy, and makes the wrapper ignore
composite target profile names. The one generated profile was moved to a
sanitized recoverable Trash path; the normal peer profile was not changed.

This directory contains only the one sampler row and sanitized startup log. It
is failure evidence, not a live or acceptance run.
