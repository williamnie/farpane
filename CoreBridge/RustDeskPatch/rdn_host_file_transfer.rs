// FarPane Native Host file-transfer receive-root primitives.
//
// This module is feature-isolated by its `rdn_host_bridge` parent and compiled
// only on macOS. The Native Host file-service owner is the only public module
// authority over descriptor-relative receive-root operations.

use hbb_common::libc;
use std::{
    collections::HashSet,
    ffi::{CStr, CString, OsStr},
    fmt,
    fs::File,
    os::unix::{
        ffi::OsStrExt,
        io::{AsRawFd, FromRawFd},
    },
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

const NATIVE_HOST_READ_MAX_ENTRIES: usize = 1_024;
const NATIVE_HOST_READ_MAX_METADATA_BYTES: usize = 1024 * 1024;
const NATIVE_HOST_READ_MAX_DEPTH: usize = 64;
const NATIVE_HOST_PRIVATE_STAGING_SUFFIX: &[u8] = b".farpane-part";

include!("rdn_host_file_transfer/types.rs");
include!("rdn_host_file_transfer/root.rs");
include!("rdn_host_file_transfer/owner.rs");
include!("rdn_host_file_transfer/directory.rs");
include!("rdn_host_file_transfer/validation.rs");
#[cfg(test)]
mod tests {
include!("rdn_host_file_transfer/tests/filesystem_operations.rs");
include!("rdn_host_file_transfer/tests/read_snapshots.rs");
}
