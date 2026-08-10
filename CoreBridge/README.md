# RustDesk Native Core Bridge

`include/rustdesk_native.h` is the stable, narrow C ABI consumed by Swift.
`Shim/rdn_shim.c` loads the Rust `cdylib` at runtime and rejects an ABI mismatch.
`RustDeskPatch/` contains the source adapter and patch against the pinned
RustDesk 1.4.9 commit. Generated RustDesk sources and compiled libraries live
under ignored `Vendor/` and `Build/` directories, not in this target.

Only encoded H264/H265 packet bytes cross this boundary. Authentication,
encryption, rendezvous, relay, and the RustDesk wire protocol stay in Rust.
ABI v2 added a single recovery command that asks the existing RustDesk session
to refresh the active display and emit a keyframe after an asynchronous
VideoToolbox decoder failure; it does not expose protocol messages to Swift.
The native client also sends RustDesk's existing non-persistent `custom_fps`
option once per session and the existing delay probe every five seconds. This
restores the capture-pacing and liveness signals normally supplied by
RustDesk's own video thread without exposing either wire message through the C
ABI.

ABI v3 adds pointer and basic keyboard input through semantic C structs. Swift
provides aspect-fit remote coordinates, button/scroll intent, Unicode scalars,
special-key identifiers and modifier flags; it never imports RustDesk protobuf
or internal Rust types. The bridge keeps clipboard/audio disabled, enables
control only for this viewer session, waits for the remote keyboard permission,
clamps coordinates to the current remote display and then reuses RustDesk's
existing `Session::send_mouse` / `Session::input_key` path.

ABI v4 distinguishes precise pixel scrolling from discrete wheel intent and
adds a bounded UTF-8 committed-text call. AppKit owns IME composition and the
candidate UI; Swift forwards only committed text, while Rust reuses
`Session::input_string`. The boundary rejects empty, invalid, NUL-containing or
over-4096-byte input without logging text content.

ABI v5 adds a semantic macOS physical-key-position variant for the opt-in
exclusive-keyboard path. Swift captures supported local key events with a
session event tap; the bridge feeds those positions into pinned RustDesk Core's
keyboard-map mode so remote shortcuts and IME composition receive real key
strokes. RustDesk Core remains solely responsible for constructing and
transmitting wire-protocol input messages.

ABI v6 added a default-off, directionally configured small-text clipboard API.
Rust accepts exactly one non-empty UTF-8 `ClipboardFormat::Text` payload up to
64 KiB, bounds decompression before decoding, rejects rich metadata and NUL,
and delivers callback-scoped bytes to Swift without touching the Viewer
pasteboard. Swift may send the same bounded semantic text through a dedicated
call only after local send policy, authentication, and the remote clipboard
permission all agree. The pinned wire exposes one clipboard negotiation bit;
the native bridge still enforces receive and send independently. FarPane's
Viewer product composition explicitly enables the small-text, rich-text, and
image directions and routes all six through one AppKit-owned pasteboard adapter.
That adapter starts only after authentication, snapshots rather than uploads
the pre-session local clipboard, suppresses its own writes, dynamically backs
polling off to four seconds, and stops before Core disconnect. Host Control ABI v15 retains the
independent, default-off bounded-text read/write policy and adds separate,
default-off rich-text and image read/write policies. The Rust Host lifetime persists the
pinned upstream Boolean only when at least one small-text, rich-text, or image direction is
explicitly requested; enabling small text never implies RTF or HTML. Host
bootstrap schema v4 projects six independent small-text, rich-text, and image
directions to the Agent. Schema v1 decodes with all clipboard directions
disabled; schema v2 preserves small text while migrating rich text and images
to disabled, and schema v3 preserves small/rich directions while migrating
images to disabled. Home exposes separate small-text, RTF/HTML, and
RGBA/PNG/SVG read/write switches only while Host is off; changing any preference
republishes the
immutable bootstrap, and Host cannot be enabled unless that publication is
coherent. The legacy foreground Host and background Agent consume the same
projection. Small text and RTF/HTML are therefore end-to-end capable after
explicit per-direction opt-in while remaining off by default. Image directions
use the same explicit, default-off Host product contract and existing Viewer
owner; file promises remain unsupported.

ABI v8 retains the ABI v7 bounded small- and rich-text contracts and adds an
independently default-off semantic image API. RGBA uses positive dimensions,
the shared 8192-side/7680x4320-pixel bounds, and exactly four bytes per pixel;
PNG uses canonical bytes under 128 MiB; SVG is bounded to 4 MiB UTF-8 and is
not treated as sanitized render input. Rust gates image receive before parsing
or decompression and rechecks before callback delivery; send uses the same
active/authenticated/local-direction/remote-permission authority. Swift copies
callback-scoped bytes synchronously and revalidates format, metadata, bounds,
PNG structure, and SVG root before queued delivery. Viewer product image directions
are explicitly enabled in device, recovery, and environment connections. The
single owner prefers `public.svg-image`, then canonical PNG, then bounded TIFF;
TIFF is decoded only after the 128 MiB input cap and pixel bounds, and is
canonicalized to PNG before crossing Core. Remote RGBA is also converted to a
bounded PNG pasteboard representation. Invalid image data fails closed without
falling back to rich or plain text, and owned-write suppression plus lifecycle
teardown remain shared. Host image directions remain default-off until the
user enables the matching Home direction. SVG is not
sanitized for rendering and is transported only as untrusted pasteboard bytes.

ABI v8 also retains the ABI v6 bounded small-text contract and the independently
default-off semantic rich-text API. One atomic callback/send payload can carry
an optional 64 KiB plain-text fallback plus at most one RTF and one HTML UTF-8
representation, each independently capped at 1 MiB. Rust rejects duplicate,
unknown, image/special, malformed, NUL, invalid UTF-8 and oversized entries;
compressed incoming representations use bounded decompression. When rich
receive is disabled, the lifecycle/permission gate runs before parsing or
decompression and is checked again before callback delivery. Swift copies all
callback-scoped bytes synchronously and shares the existing disconnect delivery
gate. The Host can now carry the same bounded semantic bundle in both
directions under its own explicit rich policy. Viewer product configuration
enables rich receive/send and the single AppKit owner reads or writes one
multi-representation item; Host product configuration exposes independent,
default-off rich read/write opt-ins through bootstrap schema v3 and Home.

The Host clipboard boundary classifies wire formats before either
directional admission point. Only bounded, non-NUL UTF-8 `Text` may use the
small-text path. RTF and HTML must form one owned semantic bundle and are
admitted only by the matching rich direction. A single RGBA, PNG, or SVG entry
must pass the independent image envelope and matching image direction; remote
`Special` format names, unknown enum values, and multi-image messages reject.

RTF/HTML now have a Rust-owned semantic envelope before any future transfer
path. It accepts only exact rich-text formats with empty special metadata and
zero image dimensions, owns the decoded UTF-8 `String`, rejects NUL, and caps
both the wire payload and bounded decompression output at 1 MiB. Host Control
ABI v15 retains separate rich read/write directions. Incoming and
outgoing messages are rebuilt as canonical, uncompressed Text/RTF/HTML entries
before reaching the pinned pasteboard helper or network writer, and the active
session's directional revoke applies before format admission. The Viewer
AppKit owner validates the same limits, reads only after `changeCount` changes,
prefers one rich bundle over a duplicate plain send, atomically writes one
`NSPasteboardItem`, and records the final owned-write count to suppress loops.
Product Host rich and image configuration remains off until the user explicitly
enables the matching Home direction. File promises remain disabled.

RGBA, PNG, and SVG now require a Rust-owned image envelope before they can even
be classified for an independent transfer. RGBA accepts bounded zstd input only
when positive dimensions are at most 8192 per side, the pixel count is at most
7680x4320, and the decoded buffer is exactly four bytes per pixel. PNG remains
canonical without a second zstd layer and has a 128 MiB wire cap; its signature,
IHDR metadata, bounded dimensions, chunk framing, image-data presence, and exact
IEND termination are checked without treating that structural check as a future
renderer. SVG has independent 4 MiB wire and decoded UTF-8 caps and rejects NUL,
DOCTYPE, and a non-canonical root. SVG is not sanitized for rendering, so a
future pasteboard owner must keep treating the bytes as untrusted. The envelope
owns its bytes. Viewer ABI v8 exposes the same default-off bounded image API;
Host Control ABI v15 now carries independent image read/write policy and both
Host directions rebuild one validated image as canonical uncompressed bytes
before the pinned pasteboard helper or network writer. Active-session revoke
precedes image parsing. Viewer product image enablement and AppKit ownership are
implemented through the single existing owner; Host bootstrap schema v4 and
Home now provide independent, default-off image read/write opt-ins. Installed
two-Mac acceptance remains unverified.

Viewer ABI v12 retains all ABI v8 clipboard behavior and the v9 separate,
default-off file-transfer seam. The connection configuration accepts exact
`false/0` desktop mode or exact `true/nonzero` dedicated file mode; file mode
rejects every desktop clipboard direction, initializes upstream
`FILE_TRANSFER`, never starts video housekeeping, never enables input, and
clears its epoch when the worker exits. Cancel requires the exact active epoch,
authentication, remote file permission and a ready session sender before it can
enqueue upstream `CancelJob`. The scalar event callback contains only epoch,
transfer ID, sequence, bounded progress and typed failure fields—never paths,
descriptors or raw protocol errors.

ABI v12 retains one exact-session, single-flight remote-root list
request. It sends only upstream `ReadDir("/", include_hidden=false)` after all
file-session and remote-permission gates pass. The callback carries a positive
request ID and callback-scoped entries: at most 1,024 regular file/directory
entries and 1 MiB aggregate UTF-8 name metadata. Empty, traversal, separated,
control-character, hidden, link/drive/unknown, private staging, nonzero-sized
directory and ASCII case-alias entries reject as one envelope. Names are copied
into Rust-owned strings, then Swift copies them again and enforces byte-exact
NFC, full case-fold collision, separator/control and size rules before queued
delivery. Disconnect and worker exit clear pending request state, while remote
errors expose only stable rejected/unavailable status. A session-bound
destination owner can now pin one pre-existing euid-owned private `0700`
directory with no-follow read-only open, retain only descriptor identity and an
opaque lease, and revalidate identity/owner/mode for each scoped borrow before
exact-epoch teardown closes it. A transport-independent recursive-manifest
authority joins one bounded files part and one bounded empty-directory part for
an exact epoch/request, then applies the canonical combined manifest validation.
ABI v12 retains the v11 root-bound recursive-manifest requests:
`AllFiles(id, "/", include_hidden=false)` and
`ReadEmptyDirs("/", include_hidden=false)`. Rust owns and bounds each response,
rejects hidden/private-staging/unsafe/type-invalid/case-alias metadata, keeps one
exact request in flight, and clears pending state on duplicate, malformed,
remote error, disconnect, worker exit or job teardown. Because
`ReadEmptyDirsResponse` has no request ID, only one manifest request is admitted
per session epoch; retry requires reconnecting with a fresh epoch, preventing a
late response from being attributed to a new request. Swift synchronously copies the
callback-scoped entries and revalidates ABI, epoch, request, status, part, type,
size, mtime, path and case-fold collisions before queued delivery. ABI v12 adds a
path-free queued download registration bound to that exact completed manifest.
Only epoch, manifest request ID, transfer ID and aggregate totals cross the ABI;
the destination lease remains Swift-owned. Admission requires the active dedicated
session, authentication, remote permission, ready sender and one of at most eight
unique transfer IDs. Cancel, terminal job callbacks, job teardown, disconnect and
worker exit clear registrations. Registered jobs now translate upstream progress,
done, error and successful cancel into exact-session callbacks with checked,
strictly increasing sequence numbers, monotonic bounded file/byte totals and stable
typed failures. Completion reports exact manifest totals; Swift validates the same
semantic envelope once before projecting it to the Viewer progress authority. The
callback is emitted after the Rust job lock is released. No download command
dispatches a wire request. The Swift destination owner can now reserve at most
eight descriptor-relative new-file staging entries: it duplicates the pinned
root, creates or revalidates private `0700` parents with `mkdirat/openat`, rejects
an existing final entry, and creates a `0600`, single-link, empty
`*.farpane-part` with `O_EXCL|O_NOFOLLOW`. Reservation handles contain no path or
descriptor; cancel, exact teardown and deinit unlink only the originally created
inode, so a replaced staging name is left untouched. This primitive does not
write payload bytes, fsync, rename/commit a final file or borrow across the ABI.
No picker UI or product configuration exists, so it remains internal rather than
file-transfer product capability.
