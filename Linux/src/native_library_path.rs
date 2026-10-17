//! Native roles load media libraries only from their own immutable release.
use std::{
    fs, io,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message)
}

fn immutable(path: &Path, executable: bool) -> io::Result<PathBuf> {
    let real = fs::canonicalize(path)?;
    let metadata = fs::metadata(&real)?;
    if !metadata.is_file() || (executable && metadata.mode() & 0o111 == 0) {
        return Err(invalid(
            "Native release entry is not the required regular file",
        ));
    }
    for ancestor in real.ancestors() {
        let metadata = fs::symlink_metadata(ancestor)?;
        if metadata.uid() != 0 || metadata.mode() & 0o022 != 0 {
            return Err(invalid("Native release is writable by an untrusted user"));
        }
    }
    Ok(real)
}

pub(super) fn drmtap(core: &Path) -> io::Result<PathBuf> {
    let core = immutable(core, true)?;
    let libexec = core
        .parent()
        .ok_or_else(|| invalid("Missing core directory"))?;
    if core.file_name().and_then(|v| v.to_str()) != Some("farpane-core")
        || libexec.file_name().and_then(|v| v.to_str()) != Some("libexec")
    {
        return Err(invalid(
            "Native core is outside an immutable release/libexec",
        ));
    }
    let release = libexec
        .parent()
        .ok_or_else(|| invalid("Missing release directory"))?;
    let directory = release.join("lib");
    // A symlink to another release or to a system directory must not cross the
    // version boundary, even when its target is also root-owned.
    if fs::canonicalize(&directory)? != directory {
        return Err(invalid("Native media directory leaves the current release"));
    }
    let library = immutable(&directory.join("libdrmtap.so.0"), false)?;
    if library.parent() != Some(directory.as_path()) {
        return Err(invalid("Native media library leaves the current release"));
    }
    Ok(library)
}
