# H4.4c Host storage migration and failure-preservation audit

## Outcome

- Audited the pinned Host configuration read/write path from the fixed `FarPaneHost/io.rustdesknative` namespace through `hbb_common::Config/Config2` and the pinned `confy` writer.
- Proved the existing process/filesystem isolation and unregister-retention boundaries, and identified concrete violations of the remaining §18 schema, migration, durability and storage-separation requirements.
- Changed no production code or external state; the audit defines H4.4d as the next safe automatic boundary.

## Requirement matrix

| §18 requirement | Current authority/evidence | Status |
|---|---|---|
| Host/Viewer config-root isolation | Agent sets `APP_NAME=FarPaneHost` and `ORG=io.rustdesknative` before the first `Config` access; its process-lifetime lease serializes the Host writer. Viewer remains in the App process and its original namespace. | Proven automatically |
| One canonical product server configuration | App publishes strict immutable `bootstrap-v1.json`; Host start copies rendezvous/relay/public-key values into the isolated `Config2.options`. H4.4b correlates the running lease revision with that bootstrap. | Proven for startup input; Rust store is still an unversioned derived copy |
| Independent Host schema version | Pinned `Config` and `Config2` are unwrapped serde structs with no `schemaVersion`, migration journal or version dispatch. `Config2.serial` is rendezvous protocol state, not a storage schema. | Missing |
| Migration is Rust-owned and failure preserving | Rust performs implicit field/default/password transformations, but every non-NotFound `confy::load_path` error is logged and replaced with `T::default()`. `Config::load` may then generate/store a new ID, and Host start writes server options before surfacing any storage health. | Contradicted: malformed old bytes can be replaced instead of retained/degraded |
| Atomic durable writes | Pinned `confy` serializes to a temporary path, applies `0600`, writes, calls `flush`, then `rename`. It does not `sync_all` the file or parent directory; temporary creation is not `create_new`/`O_EXCL` and does not reject symlinks. | Partial atomic replacement; durability and file-safety gate missing |
| Storage failures are authoritative | `Config::store_` logs and discards `store_path` errors. `set_option` returns no result; `set_permanent_password` returns true after calling the void store path, so the Host bridge can emit `permanent-password-set` even when persistence failed. | Missing/fail-open success reporting |
| Identity, server, verifier and UI preferences are separate | `Config` places encrypted ID, key pair, password verifier/salt and key-confirmation state in the same main TOML. `Config2` holds server/policy options; product UI catalog is separate. | Partial; identity and verifier are not separated |
| Sensitive values use Keychain | Rust Host configuration code has no Keychain/Security-framework ingress. The only product Keychain store is the Viewer device-password store; Host permanent-password updates call `Config::set_permanent_password`. | Missing |
| Unregister retains identity/config by default | The sole mutation owner calls only fixed `SMAppService.unregister()` and observes status. No file removal or identity reset is reachable from the unregistration UX. | Proven automatically |
| Identity deletion is a separate confirmed command | No product identity-deletion command exists. | Safe absence; future feature remains separate |

## Key evidence

- `rdn_host_start` writes four `Config2` options and then calls `Config::get_id`; it has no storage preflight before either lazy singleton is initialized.
- Pinned `load_path` returns defaults for parse, permission and other read failures. `Config::load` treats an invalid/empty identity as first-run state and calls `config.store()` after generating a replacement ID.
- `Config` has no version field and stores `enc_id`, `password`, `salt`, `key_pair`, `key_confirmed` and `keys_confirmed` together. `Config2` separately stores rendezvous/proxy/options, but also has no schema version.
- `prepare_config_for_store` explicitly clears an invalid password verifier/salt so unrelated writes can continue; this is not old-config preservation.
- Pinned `confy::do_store` performs `write_all` → `flush` → drop → `rename`, without file or directory fsync. The upstream `Config::store_` wrapper then reduces its `Result` to a log entry.
- The Host permanent-password bridge interprets `Config::set_permanent_password == true` as durable success, while the underlying store operation cannot propagate failure.
- Registration/unregistration ownership is separate from storage ownership; unregister has no filesystem or identity capability.

## Verification

- Focused bootstrap/config-root/owned-runtime/registration/unregistration suite: 37 tests, 0 failures.
- `Vendor/rustdesk` and `Vendor/rustdesk/libs/hbb_common` `git diff --check`: clean.
- Tracked upstream and hbb-common patches both pass canonical reverse-apply checks; tracked `rdn_host_bridge.rs` exactly matches the vendor build source.
- Source audit covered `docs/host-mode-design.md` §18, H0 inventory, pinned `config.rs`, Host start/permanent-password ingress, ServiceManagement mutation owner and pinned `confy` commit `83db9ec`.
- The first patch check used a repository-relative patch path after `git -C` changed path resolution and failed with file-not-found; rerunning with the correct checkout-relative paths passed all checks.
- `git diff --check` will be rerun before scoped staging.

## Next automatic boundary

H4.4d can add a Rust-only, side-effect-free Host storage preflight before any `CONFIG`/`CONFIG2` lazy access:

1. derive only the already-fixed Host paths after the one-shot namespace switch;
2. allow absent primary/secondary files as first startup;
3. require any existing file to be a bounded, private regular file and strictly deserialize into its pinned type;
4. on malformed/insecure/unreadable input, return a sanitized storage/start failure before `set_option`, ID generation, key generation or runtime creation;
5. preserve exact old bytes and perform no repair, backup, migration or deletion in this step.

This closes the immediate destructive fallback without inventing a schema. It does not satisfy versioned migration, durable writes or Keychain-backed verifier storage; those remain separate mainline architecture checkpoints because they change shared Rust storage contracts.

## Remaining manual boundary

- No user Host config, identity, password verifier, lease or server key was read.
- No App/Agent was installed, launched, registered, unregistered or deployed; nothing was pushed.
- Dual-active sessions, App-restart Host ID stability and resource budgets still require the §18/§20.3 installed two-machine acceptance matrix.
