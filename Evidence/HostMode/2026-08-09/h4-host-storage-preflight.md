# H4.4d Host storage fail-closed preflight

## Outcome

- Added a side-effect-free Rust preflight for the two fixed Host TOML files before `Config2` option mutation, `Config` identity access, password rotation or runtime creation.
- Preserved first-start behavior when the fixed directory or either document is absent.
- Converted malformed, unreadable or unsafe existing storage into the existing sanitized `-20` Host storage failure and a degraded/error lifecycle state, without repairing, backing up, deleting or replacing the document.

## Key evidence

- `preflight_host_storage` derives only `Config::file()` and `Config2::file()` after the one-shot Host namespace switch. Those path helpers read `APP_NAME/ORG` but do not initialize the `CONFIG` or `CONFIG2` lazy singletons.
- The preflight opens the fixed directory with `O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`; an existing directory must be owned by the current euid and not group/world writable.
- Each existing fixed filename is opened relative to that directory descriptor with `openat + O_NOFOLLOW + O_NONBLOCK + O_CLOEXEC`. It must be a current-euid-owned regular `0600` file with one hard link and a non-empty size no greater than 1 MiB.
- Bytes are read through the inspected descriptor with an independent upper bound. Descriptor identity/size must remain stable, UTF-8 must be valid, and the exact pinned `Config` or `Config2` type must deserialize from TOML.
- No filesystem path, TOML bytes, parser detail, identity, password material or server key enters the returned error or logs. HostCore exposes only `configuration.storagePreflightFailed` and the already-reserved storage code.
- `rdn_host_start` performs the preflight before its first state/event mutation and before every `Config::set_option`/`Config::get_id` access. Failure creates no runtime, does not bind media and leaves the instance disposable through the existing destroy path.
- Rust fixtures prove absent storage is not created; valid private documents retain exact bytes; malformed primary/secondary documents retain exact bytes; symlink, hardlink, non-regular, loose-mode, oversized and writable-directory cases fail closed.
- The built-core ABI lifecycle uses only `FarPaneHostTestsRoot.FarPaneHostTests` under the pinned macOS `Preferences` path. A malformed primary document returns `-20`, remains byte-identical and does not create the secondary document; after destroying the failed instance and removing the test document, a new instance completes the normal lifecycle.

## Verification

- `cargo test --manifest-path Vendor/rustdesk/Cargo.toml --lib --features rdn-native-core,rdn-native-host host_storage_preflight`: 5 tests, 0 failures.
- Complete `rdn_host_bridge::tests::` Rust group: 22 tests, 0 failures.
- `scripts/build-rust-core.sh`: rebuilt the arm64 Release dylib successfully.
- Built-core `HostBridgeContractTests/testFullHostCoreLifecycle`: 1 test, 0 failures, including malformed-storage preservation and recovery through a fresh instance.
- `CoreBridgeContractTests/testHostStoragePreflightPrecedesConfigMutationAndIdentityAccess`: 1 test, 0 failures.
- `swift test`: 720 tests, 4 environment-gated skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- Tracked Host bridge exactly matches the vendor build source; both pinned patch reverse-apply checks and vendor `diff --check` checks pass.
- `git diff --check`: clean before scoped staging.

## Corrected test-path assumption

- The first built-core attempt placed its malformed fixture under `Library/Application Support/...` and correctly observed a normal start because pinned `hbb_common::config::patch` maps the macOS `ProjectDirs` result into `Library/Preferences/<org>.<app>`.
- The exact throwaway directory created by that failed test attempt was moved to Trash. The test was corrected to the pinned `Preferences/FarPaneHostTestsRoot.FarPaneHostTests` path and then passed; no real `FarPaneHost` product storage was opened or changed.

## Remaining boundary

- This preflight prevents destructive fallback but does not add a Host schema version, migration journal, repair UX or automatic backup.
- The pinned writer still lacks file/directory `fsync`, exclusive temporary creation and write-error propagation. Permanent-password success still cannot prove durable persistence.
- Identity/keypair and permanent-password verifier/salt remain co-located, and Host verifier storage is not Keychain-backed.
- H4.4 dual-active-session, App-restart Host ID stability and split-process resource budgets still require installed two-machine evidence after device recovery.
- No App/Agent was installed, launched, registered or deployed; Hermes, CI, root dependencies and shared ABI/schema were unchanged, and nothing was pushed.
