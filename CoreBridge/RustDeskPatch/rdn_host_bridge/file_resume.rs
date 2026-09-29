#[cfg(target_os = "macos")]
#[derive(Debug)]
struct NativeHostPreparedWriteEntry {
    destination_path: PathBuf,
    staging_path: PathBuf,
    expected_size: u64,
    modified_time: u64,
}

#[cfg(target_os = "macos")]
#[derive(Debug)]
struct NativeHostResumeMetadata {
    expected_size: u64,
    modified_time: u64,
    committed_size: u64,
    prefix_digest: [u8; 32],
}

#[cfg(target_os = "macos")]
impl NativeHostResumeMetadata {
    fn encode(&self) -> [u8; NATIVE_HOST_RESUME_METADATA_BYTES] {
        let mut encoded = [0_u8; NATIVE_HOST_RESUME_METADATA_BYTES];
        encoded[0..8].copy_from_slice(NATIVE_HOST_RESUME_METADATA_MAGIC);
        encoded[8..16].copy_from_slice(&self.expected_size.to_be_bytes());
        encoded[16..24].copy_from_slice(&self.modified_time.to_be_bytes());
        encoded[24..32].copy_from_slice(&self.committed_size.to_be_bytes());
        encoded[32..64].copy_from_slice(&self.prefix_digest);
        encoded
    }

    fn decode(encoded: &[u8]) -> Result<Self, NativeHostWriteJobError> {
        if encoded.len() != NATIVE_HOST_RESUME_METADATA_BYTES
            || &encoded[0..8] != NATIVE_HOST_RESUME_METADATA_MAGIC
        {
            return Err(NativeHostWriteJobError::ResumeStateInvalid);
        }
        let read_u64 = |range: std::ops::Range<usize>| {
            let mut bytes = [0_u8; 8];
            bytes.copy_from_slice(&encoded[range]);
            u64::from_be_bytes(bytes)
        };
        let mut prefix_digest = [0_u8; 32];
        prefix_digest.copy_from_slice(&encoded[32..64]);
        Ok(Self {
            expected_size: read_u64(8..16),
            modified_time: read_u64(16..24),
            committed_size: read_u64(24..32),
            prefix_digest,
        })
    }
}

#[cfg(target_os = "macos")]
#[derive(Debug)]
struct NativeHostWriteFile {
    owner: Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>,
    staging_path: PathBuf,
    destination_path: PathBuf,
    file: Option<File>,
    expected_size: u64,
    written_size: u64,
    modified_time: u64,
    prefix_hasher: Sha256,
    preserve_for_resume: bool,
    committed: bool,
}

#[cfg(target_os = "macos")]
impl NativeHostWriteFile {
    fn create(
        owner: Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>,
        entry: &NativeHostPreparedWriteEntry,
    ) -> Result<Self, NativeHostWriteJobError> {
        let file = owner
            .create_new_file(&entry.staging_path)
            .map_err(|_| NativeHostWriteJobError::Storage)?;
        let prefix_hasher = Sha256::new();
        let created = Self {
            owner,
            staging_path: entry.staging_path.clone(),
            destination_path: entry.destination_path.clone(),
            file: Some(file),
            expected_size: entry.expected_size,
            written_size: 0,
            modified_time: entry.modified_time,
            prefix_hasher,
            preserve_for_resume: false,
            committed: false,
        };
        native_host_set_resume_metadata(
            created
                .file
                .as_ref()
                .ok_or(NativeHostWriteJobError::Storage)?,
            &native_host_write_resume_metadata(entry, 0, &created.prefix_hasher),
        )?;
        created
            .file
            .as_ref()
            .ok_or(NativeHostWriteJobError::Storage)?
            .sync_all()
            .map_err(|_| NativeHostWriteJobError::Storage)?;
        Ok(created)
    }

    fn resume(
        owner: Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>,
        entry: &NativeHostPreparedWriteEntry,
    ) -> Result<Option<Self>, NativeHostWriteJobError> {
        let Some(mut file) = owner
            .try_open_existing_file_for_resume(&entry.staging_path)
            .map_err(|_| NativeHostWriteJobError::ResumeStateInvalid)?
        else {
            return Ok(None);
        };
        let metadata = native_host_get_resume_metadata(&file)?;
        if metadata.expected_size != entry.expected_size
            || metadata.modified_time != entry.modified_time
            || metadata.committed_size == 0
            || metadata.committed_size > entry.expected_size
            || metadata.committed_size > u32::MAX as u64
        {
            return Err(NativeHostWriteJobError::ResumeStateInvalid);
        }
        let stored_size = file
            .metadata()
            .map_err(|_| NativeHostWriteJobError::ResumeStateInvalid)?
            .len();
        if stored_size < metadata.committed_size || stored_size > entry.expected_size {
            return Err(NativeHostWriteJobError::ResumeStateInvalid);
        }
        if stored_size != metadata.committed_size {
            file.set_len(metadata.committed_size)
                .map_err(|_| NativeHostWriteJobError::ResumeStateInvalid)?;
        }
        let prefix_hasher = native_host_read_and_verify_resume_prefix(
            &mut file,
            metadata.committed_size,
            &metadata.prefix_digest,
        )?;
        Ok(Some(Self {
            owner,
            staging_path: entry.staging_path.clone(),
            destination_path: entry.destination_path.clone(),
            file: Some(file),
            expected_size: entry.expected_size,
            written_size: metadata.committed_size,
            modified_time: entry.modified_time,
            prefix_hasher,
            preserve_for_resume: true,
            committed: false,
        }))
    }

    fn write_payload(&mut self, payload: &[u8]) -> Result<(), NativeHostWriteJobError> {
        let next_size = self
            .written_size
            .checked_add(payload.len() as u64)
            .ok_or(NativeHostWriteJobError::FileSizeExceeded)?;
        if next_size > self.expected_size {
            return Err(NativeHostWriteJobError::FileSizeExceeded);
        }
        let file = self.file.as_mut().ok_or(NativeHostWriteJobError::Storage)?;
        std::io::Write::write_all(file, payload).map_err(|_| NativeHostWriteJobError::Storage)?;
        self.prefix_hasher.update(payload);
        native_host_set_resume_metadata(
            file,
            &NativeHostResumeMetadata {
                expected_size: self.expected_size,
                modified_time: self.modified_time,
                committed_size: next_size,
                prefix_digest: native_host_prefix_digest(&self.prefix_hasher),
            },
        )?;
        file.sync_all()
            .map_err(|_| NativeHostWriteJobError::Storage)?;
        self.written_size = next_size;
        self.preserve_for_resume = next_size > 0;
        Ok(())
    }

    fn commit(mut self) -> Result<(), NativeHostWriteJobError> {
        if self.written_size != self.expected_size {
            return Err(NativeHostWriteJobError::FileSizeMismatch);
        }
        self.preserve_for_resume = false;
        let file = self.file.take().ok_or(NativeHostWriteJobError::Storage)?;
        native_host_set_file_modified_time(&file, self.modified_time)?;
        native_host_remove_resume_metadata(&file)?;
        file.sync_all()
            .map_err(|_| NativeHostWriteJobError::Storage)?;
        let stored_size = file
            .metadata()
            .map_err(|_| NativeHostWriteJobError::Storage)?
            .len();
        if stored_size != self.expected_size {
            return Err(NativeHostWriteJobError::FileSizeMismatch);
        }
        drop(file);
        self.owner
            .rename_entry(&self.staging_path, &self.destination_path)
            .map_err(|_| NativeHostWriteJobError::Storage)?;
        self.committed = true;
        Ok(())
    }
}

#[cfg(target_os = "macos")]
impl Drop for NativeHostWriteFile {
    fn drop(&mut self) {
        self.file.take();
        if !self.committed && !self.preserve_for_resume {
            let _ = self.owner.remove_file(&self.staging_path);
        }
    }
}

#[cfg(target_os = "macos")]
fn native_host_write_resume_metadata(
    entry: &NativeHostPreparedWriteEntry,
    committed_size: u64,
    prefix_hasher: &Sha256,
) -> NativeHostResumeMetadata {
    NativeHostResumeMetadata {
        expected_size: entry.expected_size,
        modified_time: entry.modified_time,
        committed_size,
        prefix_digest: native_host_prefix_digest(prefix_hasher),
    }
}

#[cfg(target_os = "macos")]
fn native_host_prefix_digest(hasher: &Sha256) -> [u8; 32] {
    let digest = hasher.clone().finalize();
    let mut bytes = [0_u8; 32];
    bytes.copy_from_slice(&digest);
    bytes
}

#[cfg(target_os = "macos")]
fn native_host_set_resume_metadata(
    file: &File,
    metadata: &NativeHostResumeMetadata,
) -> Result<(), NativeHostWriteJobError> {
    let encoded = metadata.encode();
    let result = unsafe {
        libc::fsetxattr(
            file.as_raw_fd(),
            NATIVE_HOST_RESUME_XATTR_NAME.as_ptr().cast(),
            encoded.as_ptr().cast(),
            encoded.len(),
            0,
            0,
        )
    };
    if result != 0 {
        return Err(NativeHostWriteJobError::Storage);
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn native_host_get_resume_metadata(
    file: &File,
) -> Result<NativeHostResumeMetadata, NativeHostWriteJobError> {
    let mut encoded = [0_u8; NATIVE_HOST_RESUME_METADATA_BYTES];
    let size = unsafe {
        libc::fgetxattr(
            file.as_raw_fd(),
            NATIVE_HOST_RESUME_XATTR_NAME.as_ptr().cast(),
            encoded.as_mut_ptr().cast(),
            encoded.len(),
            0,
            0,
        )
    };
    if size != encoded.len() as isize {
        return Err(NativeHostWriteJobError::ResumeStateInvalid);
    }
    NativeHostResumeMetadata::decode(&encoded)
}

#[cfg(target_os = "macos")]
fn native_host_remove_resume_metadata(file: &File) -> Result<(), NativeHostWriteJobError> {
    if unsafe {
        libc::fremovexattr(
            file.as_raw_fd(),
            NATIVE_HOST_RESUME_XATTR_NAME.as_ptr().cast(),
            0,
        )
    } != 0
    {
        return Err(NativeHostWriteJobError::Storage);
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn native_host_read_and_verify_resume_prefix(
    file: &mut File,
    committed_size: u64,
    expected_digest: &[u8; 32],
) -> Result<Sha256, NativeHostWriteJobError> {
    file.seek(std::io::SeekFrom::Start(0))
        .map_err(|_| NativeHostWriteJobError::ResumeStateInvalid)?;
    let mut remaining = committed_size;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    while remaining > 0 {
        let requested = usize::try_from(remaining.min(buffer.len() as u64))
            .map_err(|_| NativeHostWriteJobError::ResumeStateInvalid)?;
        file.read_exact(&mut buffer[..requested])
            .map_err(|_| NativeHostWriteJobError::ResumeStateInvalid)?;
        hasher.update(&buffer[..requested]);
        remaining -= requested as u64;
    }
    if native_host_prefix_digest(&hasher) != *expected_digest {
        return Err(NativeHostWriteJobError::ResumeStateInvalid);
    }
    file.seek(std::io::SeekFrom::Start(committed_size))
        .map_err(|_| NativeHostWriteJobError::ResumeStateInvalid)?;
    Ok(hasher)
}
