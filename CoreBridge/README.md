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
Viewer product composition explicitly enables both text directions and routes
them through one AppKit-owned pasteboard adapter. That adapter starts only
after authentication, snapshots rather than uploads the pre-session local
clipboard, suppresses its own writes, dynamically backs polling off to four
seconds, and stops before Core disconnect. Host Control ABI v14 retains the
independent, default-off bounded-text read/write policy and adds separate,
default-off rich-text read/write policy. The Rust Host lifetime persists the
pinned upstream Boolean only when at least one small- or rich-text direction is
explicitly requested; enabling small text never implies RTF or HTML. Host
bootstrap schema v2 projects only the small-text policy to the Agent while
schema v1 decodes as disabled. Home exposes two small-text switches only while
Host is off; changing either preference republishes the immutable bootstrap,
and Host cannot be enabled unless that publication is coherent. The legacy
foreground Host and background Agent consume the same projection. Small text
is therefore end-to-end capable after explicit opt-in while remaining off by
default; rich product enablement, images, and file promises are still
unsupported.

ABI v7 retains the ABI v6 bounded small-text contract and adds an independently
default-off semantic rich-text API. One atomic callback/send payload can carry
an optional 64 KiB plain-text fallback plus at most one RTF and one HTML UTF-8
representation, each independently capped at 1 MiB. Rust rejects duplicate,
unknown, image/special, malformed, NUL, invalid UTF-8 and oversized entries;
compressed incoming representations use bounded decompression. When rich
receive is disabled, the lifecycle/permission gate runs before parsing or
decompression and is checked again before callback delivery. Swift copies all
callback-scoped bytes synchronously and shares the existing disconnect delivery
gate. The Host can now carry the same bounded semantic bundle in both
directions under its own explicit rich policy, but product configuration does
not enable those Host directions; the rich AppKit pasteboard owner remains disabled.

The Host rich-payload boundary classifies wire clipboard formats before either
directional admission point. Only bounded, non-NUL UTF-8 `Text` may use the
small-text path. RTF and HTML must form one owned semantic bundle and are
admitted only by the matching rich direction; RGBA, PNG, SVG, remote `Special`
format names, and unknown enum values still reject outright. Classification
alone does not enable rich clipboard transport.

RTF/HTML now have a Rust-owned semantic envelope before any future transfer
path. It accepts only exact rich-text formats with empty special metadata and
zero image dimensions, owns the decoded UTF-8 `String`, rejects NUL, and caps
both the wire payload and bounded decompression output at 1 MiB. Host Control
ABI v14 binds this path to separate rich read/write directions. Incoming and
outgoing messages are rebuilt as canonical, uncompressed Text/RTF/HTML entries
before reaching the pinned pasteboard helper or network writer, and the active
session's directional revoke applies before format admission. Product Host
configuration, the Viewer AppKit owner, image payloads, and file promises remain
disabled.
