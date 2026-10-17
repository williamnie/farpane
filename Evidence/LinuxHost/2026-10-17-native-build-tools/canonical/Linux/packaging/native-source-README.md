# FarPane native source snapshot

This development source snapshot accompanies the exact native core and GUI
hashes in `binary-build-receipt.json`. It is not a completed release audit or
a claim that a fresh full build has passed.

`Linux/` and `Scripts/linux/` contain the canonical implementation, patches,
pins, locks, build/installation tools and documentation. `Build/Linux/src/`
contains full source trees reconstructed from fixed Git objects or verified
archives, then patched with the canonical changes. Each entire prepared tree
was compared with the current build source, including file bytes and links.
The native GUI/protocol/file crates retain their original prepared layout.
The comparison explicitly lists excluded old Flutter build/cache/plugin and
bridge-generator outputs; their pinned originals remain in this snapshot.
The Rust Flutter bridge modules are cfg-disabled in the Linux native build.
`src/version.rs` is the observed
output of the upstream version/date generator; it is recorded separately,
not claimed to be pinned Git content or proof of the original release date.

`vendor/` and `.cargo/config.toml` are Cargo's offline source replacement for
both locked core and GUI dependency graphs. The vendor set includes inactive
target dependencies; its size is not the running application's dependency or
memory footprint. Cargo credentials, registry indexes, Git object caches,
compiler targets and installed application binaries are not copied.

`native-dependencies/ports/` contains the exact non-FFmpeg recipe trees,
checked against the original installed ABI records. `downloads/` contains
their verified source archives, including the fixed AOM/libyuv Git exports.
The pinned vcpkg source and cached ABI records are supplied separately.
`native-dependencies/notice-supplements/` retains inspected original notice
texts which may be embedded in sources or omitted by Cargo package filters.
Their package/file/nested-component scopes are recorded separately; a nested
notice is not treated as permission for the outer Rust wrapper. This collection
does not close the remaining inventory or license/source audit records.
FFmpeg 9.0.2, AMF 1.5.2 and the pinned Meson wheel remain under
`Build/Linux/downloads/`; their pins are in `Linux/dependencies.lock.json`.
Do not use the old FFmpeg/AMF recipes from the vcpkg checkout for this product.

After extraction, run Cargo from the snapshot root so that it reads the
included `.cargo/config.toml`. With Rust 1.89.0 and an empty task-specific
`CARGO_HOME`, the dependency graphs can be inspected offline:

```sh
cargo metadata --offline --locked --filter-platform x86_64-unknown-linux-gnu \
  --manifest-path Build/Linux/src/rustdesk/Cargo.toml --no-default-features \
  --features farpane-native,linux-gpu-media --format-version 1
cargo metadata --offline --locked --filter-platform x86_64-unknown-linux-gnu \
  --manifest-path Build/Linux/gui/Cargo.toml --format-version 1
```

Application compilation also requires the native dependencies, compiler and
system development libraries described in `Linux/docs/native-package.md`.
The original product build wrappers still reference the linux-host builder/cache
setup. `Linux/docs/native-bootstrap.md` describes a separate Ubuntu 24.04
entrypoint for building the pinned non-FFmpeg dependencies in a fresh prefix.
Its result records remain separate from the product's original cached ABI
records. `Linux/docs/native-source-build.md` records the subsequent complete
media/core/GUI build and isolated software connections, bound to the exact
source snapshot used. Those later results do not rewrite a frozen manifest,
prove bit-for-bit reproduction, or close the real-desktop/release audit.

`Linux/docs/native-build-tools.md` describes fetching checksum-pinned official
Rust SDK, vcpkg and CMake archives. `prepare-native-tools.py` installs Rust only
inside an unprivileged container into a new Build/ prefix. Set
`FARPANE_NATIVE_RUST_SDK` to that verified SDK for the source build wrappers;
an existing linux-host SDK is no longer required. Application compilation remains
offline after acquisition. This does not build the Rust/GCC toolchains from
source or claim that a public CI run has completed.

`Linux/docs/native-source-package.md` describes packaging a completed isolated
build with `package-native.py --source-build`. This snapshot includes the root
`THIRD_PARTY_NOTICES.md` needed by the packager. An extracted snapshot uses its
manifest identity instead of discovering a Git repository in a parent folder.
Compilation provenance and packaging provenance remain separate. The optional
`compiled_source_build` manifest record binds a source build's actual binaries;
it does not claim this newly assembled archive was itself cold-built again.

`source-manifest.json` binds file hashes, links, executable bits and binary
identities. The adjacent archive SHA-256 checks integrity, not publisher
identity. `Linux/docs/native-source-materials.md` records unresolved notice
locations and the limits of the license inventory. Embedded third-party code,
all corresponding-source obligations, system/toolchain prerequisites and the
public release audit still need completion; no permission is inferred from
this snapshot's existence. Do not publish it as an accepted source release.
