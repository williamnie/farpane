# H5.3am native-architecture package readiness

## Outcome

Extended `Scripts/build-universal.sh` with an explicit, bounded
`RDN_BUILD_ARCHITECTURES` override while preserving `arm64 x86_64` as the
default. The accepted values are exactly `arm64`, `x86_64`, or
`arm64 x86_64`; every requested architecture must have its matching Swift
executable and `Build/CoreBridge/<arch>/liblibrustdesk.dylib`.

This prevents a machine without Rosetta from silently packaging the stale
x86_64 Core alongside current Swift/Host ABI code. The current Mini can now
produce a current arm64 package, and an Intel Mac can later use the same entry
point with `RDN_BUILD_ARCHITECTURES=x86_64`.

## Read-only installed readiness

Before building, the installed state was inspected without launching or
mutating a service:

- `/Applications/FarPane.app` existed with a valid signature, build
  `20260808131034`, version `0.1.0` and the expected bundle identifier.
- Exact service `gui/501/io.rustdesknative.viewer.host-agent` was not
  registered.
- No installed FarPane App or HostAgent process was running.
- No real passing `farpane-host-combined-role-pair` JSON was present; the only
  repository matches were documentation references.

Therefore the installed state was not eligible for H5.3al runtime capture.
No matrix attempt was made.

## Fresh arm64 package

The current tracked Host bridge was freshly rebuilt from the pinned RustDesk
commit and tracked patch. The selected vcpkg dependencies were already pinned
and present. The current Swift product was then packaged with the single
available native architecture and stable Apple Development signing:

```text
BUILD_NUMBER=202608100549
SIGNING_MODE=stable-identity
BUILD_ARCHITECTURES=arm64
```

Stable artifacts:

```text
Build/HostMode-arm64-202608100549/FarPane.app
Build/HostMode-arm64-202608100549/FarPane-arm64-202608100549.zip
```

The zip SHA-256 is
`ea0ac0ecd4d2c6fb2a2448e4ba98e2cf12a98f8075e2b9cd97c883f03689f8af`.
The App is 24 MiB and the zip is 11 MiB.

## Verification

- Fresh arm64 Rust Core build: pass; pinned upstream source and required
  symbols verified by `Scripts/build-rust-core.sh`.
- Stable-signed arm64 App build: pass.
- App and embedded Core architectures: exact `arm64`.
- App, embedded Core, copied App and zip-extracted App deep/strict signature
  verification: pass.
- Info.plist and bundled LaunchAgent plist lint: pass; bundled LaunchAgent is
  byte-identical to the tracked asset.
- Full Swift tests with the exact packaged fresh Core loaded: 897/897.
- Focused release metadata tests: 5/5.
- Shell syntax, invalid-architecture rejection and diff checks: pass.

## Remaining boundary

The package was not installed and no App or HostAgent process/service was
started, stopped, registered or changed. H5.3al still requires a user-approved
install on the Mini, Host background registration, a real passing H5.3u
item-10 result, and the five operator-driven two-machine scenarios. The Intel
package must be built on an Intel/Rosetta-capable machine after the MBP is
available; the stale x86_64 Core was deliberately not used.
