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
seconds, and stops before Core disconnect. Host Control ABI v13 now carries
independent, default-off read/write policy into the Rust Host lifetime and
persists the upstream Boolean only when either bounded direction is explicitly
requested. Host bootstrap schema v2 projects the same independent policy to the
Agent while schema v1 decodes as disabled. Home exposes two explicit switches
only while Host is off; changing either preference republishes the immutable
bootstrap, and Host cannot be enabled unless that publication is coherent. The
legacy foreground Host and background Agent consume the same projection. Small
text is therefore end-to-end capable after explicit opt-in while remaining off
by default; images and file promises are still unsupported.

ABI v7 retains the ABI v6 bounded small-text contract and adds an independently
default-off semantic rich-text API. One atomic callback/send payload can carry
an optional 64 KiB plain-text fallback plus at most one RTF and one HTML UTF-8
representation, each independently capped at 1 MiB. Rust rejects duplicate,
unknown, image/special, malformed, NUL, invalid UTF-8 and oversized entries;
compressed incoming representations use bounded decompression. When rich
receive is disabled, the lifecycle/permission gate runs before parsing or
decompression and is checked again before callback delivery. Swift copies all
callback-scoped bytes synchronously and shares the existing disconnect delivery
gate. No AppKit pasteboard owner or product configuration enables the rich
directions yet, and Host rich admission/transport remains a later boundary.

The Host rich-payload boundary now classifies wire clipboard formats before
either directional admission point. Only bounded, non-NUL UTF-8 `Text` may use
the existing inline path. RTF, HTML, RGBA, PNG, and SVG are explicitly routed
to a future independent transfer owner and remain rejected by the current
read/write gates; remote `Special` format names and unknown enum values reject
outright. Classification does not enable rich clipboard transport.

RTF/HTML now have a Rust-owned semantic envelope before any future transfer
path. It accepts only exact rich-text formats with empty special metadata and
zero image dimensions, owns the decoded UTF-8 `String`, rejects NUL, and caps
both the wire payload and bounded decompression output at 1 MiB. The current
Host data plane still admits only `InlineSmallText`: ABI v7 can safely represent
Viewer rich text, but no Host rich admission, network transfer owner, AppKit
pasteboard integration, image payload, or product enablement is connected yet.
