//! Immutable, bounded shared pixels for the software compatibility path.
use std::{
    fs::File,
    io::{self, Write},
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    ptr::NonNull,
};
const LIMIT: usize = 2560 * 1600 * 4;
const SEALS: i32 = libc::F_SEAL_SHRINK | libc::F_SEAL_GROW | libc::F_SEAL_WRITE | libc::F_SEAL_SEAL;
pub fn create(bytes: &[u8]) -> io::Result<OwnedFd> {
    create_parts(&[bytes], LIMIT, c"farpane-frame")
}
pub(crate) fn create_parts(
    parts: &[&[u8]],
    limit: usize,
    name: &std::ffi::CStr,
) -> io::Result<OwnedFd> {
    let length = parts.iter().try_fold(0usize, |n, p| n.checked_add(p.len()));
    if length.is_none_or(|n| n == 0 || n > limit) {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    let raw =
        unsafe { libc::memfd_create(name.as_ptr(), libc::MFD_CLOEXEC | libc::MFD_ALLOW_SEALING) };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut file = unsafe { File::from_raw_fd(raw) };
    for bytes in parts {
        file.write_all(bytes)?;
    }
    if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_ADD_SEALS, SEALS) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(file.into())
}
pub struct Bytes {
    address: NonNull<libc::c_void>,
    length: usize,
    _fd: OwnedFd,
}
// mmap is PROT_READ and every mutable/file-size operation is permanently sealed.
unsafe impl Send for Bytes {}
unsafe impl Sync for Bytes {}
impl Bytes {
    pub fn map(fd: OwnedFd, length: usize) -> io::Result<Self> {
        Self::map_with_limit(fd, length, LIMIT)
    }
    pub(crate) fn map_with_limit(fd: OwnedFd, length: usize, limit: usize) -> io::Result<Self> {
        let seals = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GET_SEALS) };
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        if length == 0
            || length > limit
            || seals < 0
            || seals & SEALS != SEALS
            || unsafe { libc::fstat(fd.as_raw_fd(), stat.as_mut_ptr()) } != 0
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Unsealed or invalid shared pixels",
            ));
        }
        let stat = unsafe { stat.assume_init() };
        if stat.st_size != length as i64 || stat.st_mode & libc::S_IFMT != libc::S_IFREG {
            return Err(io::ErrorKind::InvalidData.into());
        }
        let address = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                length,
                libc::PROT_READ,
                libc::MAP_SHARED,
                fd.as_raw_fd(),
                0,
            )
        };
        if address == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }
        Ok(Self {
            address: NonNull::new(address).expect("non-null mmap"),
            length,
            _fd: fd,
        })
    }
}
impl AsRef<[u8]> for Bytes {
    fn as_ref(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.address.as_ptr().cast(), self.length) }
    }
}
impl Drop for Bytes {
    fn drop(&mut self) {
        unsafe {
            libc::munmap(self.address.as_ptr(), self.length);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shared_pixels_cannot_change_or_shrink_under_the_gui() {
        let fd = create(b"immutable pixels").unwrap();
        assert_eq!(unsafe { libc::ftruncate(fd.as_raw_fd(), 0) }, -1);
        assert_eq!(
            unsafe { libc::pwrite(fd.as_raw_fd(), b"x".as_ptr().cast(), 1, 0) },
            -1
        );
        let bytes = Bytes::map(fd, 16).unwrap();
        assert_eq!(bytes.as_ref(), b"immutable pixels");
        assert!(Bytes::map(create(b"short").unwrap(), 16).is_err());
        assert!(Bytes::map(File::open("/dev/zero").unwrap().into(), 16).is_err());
    }
}
