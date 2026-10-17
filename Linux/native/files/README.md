# Native file-transfer storage and ownership

This crate is the filesystem and per-connection ownership layer for the Linux
GUI rewrite. The native Host/Viewer wire adapters and GTK companion window now
use it for bounded directory browsing, individual-file upload/download,
multi-selection uploads and streaming directory transfers in both directions.
This does not yet provide the complete folder-transfer/interoperability matrix.
It has no GUI/media dependency;
`libc` is pinned in the adjacent Cargo.lock.

- `Root` opens an explicitly selected, private, user-owned directory. Remote
  paths remain relative to its descriptor; `openat2` rejects symlinks and
  traversal. `provision` creates only an explicit private leaf and never chmods
  existing user directories. `Source` exposes read-only access to an explicitly
  selected local upload directory, including ordinary 0755 directories.
- Readers emit at most 128 KiB per call. Receivers write a private staging file,
  check the declared size, fsync and rename at completion. Cancellation removes
  only the staging inode that this writer created. Existing destinations remain
  intact on cancellation or incomplete input. Already committed files in an
  interrupted batch remain; this is not an atomic whole-directory transaction.
- Directory pages contain at most 128 entries / 16 KiB of metadata, with at most
  4096 entries examined per call. `Source::walk` retains at most 64 directory
  cursors, not a recursive manifest. Unsupported names, links, special files and
  staging files are excluded. Receive manifests have the same metadata bound.
- `outgoing::Plan` keeps one manifest and one lookahead entry. Selected local
  folders retain `Source` authority; `shared_folder` retains the original private
  `Root` authority even when walking an ordinary 0755 child. Readers and cursors
  continue to check that root. A selected directory's empty root entry preserves
  empty folders. Unsupported objects are counted and reported, not followed.
- `Owner` binds local task keys and one listing cursor to a connection generation.
  It limits active jobs to eight, separates local consent from peer messages,
  requires explicit overwrite authority, rejects stale cursors/decisions and
  drops partial writers on cancellation/revocation/errors. Pending consent
  expires after 60 seconds and idle work after 120 seconds when the event loop
  calls `expire`. An expired cursor must be restarted. Revocation is permanent
  for that owner; a new grant needs a new, unique generation.
- Root/parent privacy and ownership are rechecked on open handles. Replacing a
  path does not redirect the selected descriptor. These checks do not protect
  against an attacker with the same UID deliberately modifying the process or
  racing its own files; kernel file operations can also block on a failing disk.

The adapters are `Linux/native/files.rs`, `file_host.rs` and `file_viewer.rs`.
They authenticate a separate file connection, allocate unique owner generations,
route local consent through the authenticated GUI control channel, and use bounded
queues on dedicated file I/O threads. Host workers stop on policy/connection
changes; successful revoke acknowledgements wait for owner/writer cleanup. Both
storage and wire state have idle deadlines, including the final completion wait.
Packets are capped before protobuf parsing, and zstd output/window sizes are
bounded. No filesystem operations run on GTK or the video network loop.

Native peers separately negotiate paged browsing and batched upload/download.
A legacy request that cannot
fit one bounded page receives an explicit error instead of a truncated directory.
Upload completion is acknowledged after Host commit; `Read::End` on a download
proves only local EOF, so Host reports `sent` rather than claiming remote persistence.
Viewer reports download completion only after its own writer commits. Native
directory downloads additionally acknowledge each committed batch; Host waits
for the last acknowledgement before reporting completion. The protocol contract
is in `Linux/docs/file-transfer-protocol.md`. Real native
GTK ordinary/empty-file roundtrip, consent, overwrite/rejection, mid-write
revocation, hashes and process cleanup have passed in
isolated loopback/Xvfb tests. Folder fault coverage, legacy/Mac interoperability, full
fault/permission/lifecycle coverage and real-desktop acceptance remain pending.

```sh
python3 -B Scripts/linux/prepare-native.py
Scripts/linux/native-container.sh -c 'cd Build/Linux/native/files && cargo test --offline --locked'
python3 -B Scripts/linux/prepare-native.py --check
Scripts/linux/test-native-viewer.sh files
Scripts/linux/test-native-viewer.sh files-matrix
Scripts/linux/test-native-viewer.sh files-tree
```

The tests operate only on temporary directories in the isolated builder.
Generated crates, targets and caches belong under `Build/Linux/`.
