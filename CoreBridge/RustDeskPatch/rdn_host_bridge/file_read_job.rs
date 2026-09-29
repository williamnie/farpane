#[cfg(target_os = "macos")]
#[derive(Debug)]
pub(crate) struct NativeHostReadJob {
    id: i32,
    owner: Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>,
    wire_path: String,
    entries: Vec<rdn_host_file_transfer::NativeHostReadEntry>,
    next_file_num: usize,
    current_file: Option<File>,
    current_offset: u64,
    awaiting_confirmation: Option<usize>,
    overwrite_detection: bool,
}

#[cfg(target_os = "macos")]
impl NativeHostReadJob {
    pub(crate) fn id(&self) -> i32 {
        self.id
    }

    pub(crate) fn wire_path(&self) -> &str {
        &self.wire_path
    }

    pub(crate) fn entries(&self) -> Vec<NativeHostReadListEntry> {
        self.entries
            .iter()
            .map(native_host_read_list_entry)
            .collect()
    }

    pub(crate) fn is_waiting_for_confirmation(&self) -> bool {
        self.awaiting_confirmation.is_some()
    }

    pub(crate) fn is_current(&self) -> bool {
        let broker = MEDIA_BROKER.lock().unwrap();
        broker.binding.is_some()
            && broker
                .file_service_owner
                .as_ref()
                .is_some_and(|owner| Arc::ptr_eq(owner, &self.owner))
    }

    pub(crate) fn confirm(
        &mut self,
        file_num: i32,
        confirmation: NativeHostReadConfirmation,
    ) -> Result<(), NativeHostReadJobError> {
        if !self.is_current() {
            return Err(NativeHostReadJobError::Unavailable);
        }
        let file_num =
            usize::try_from(file_num).map_err(|_| NativeHostReadJobError::InvalidFileNumber)?;
        if self.awaiting_confirmation != Some(file_num)
            || file_num != self.next_file_num
            || file_num >= self.entries.len()
        {
            return Err(NativeHostReadJobError::InvalidConfirmation);
        }
        self.owner
            .verify_read_file(
                self.current_file
                    .as_ref()
                    .ok_or(NativeHostReadJobError::InvalidConfirmation)?,
                &self.entries[file_num],
            )
            .map_err(native_host_read_job_error)?;
        match confirmation {
            NativeHostReadConfirmation::Skip => {
                self.current_file.take();
                self.current_offset = 0;
                self.next_file_num = file_num
                    .checked_add(1)
                    .ok_or(NativeHostReadJobError::InvalidFileNumber)?;
            }
            NativeHostReadConfirmation::ContinueAt { offset } => {
                let offset = u64::from(offset);
                if offset > self.entries[file_num].size() {
                    return Err(NativeHostReadJobError::OffsetOutOfRange);
                }
                self.current_file
                    .as_mut()
                    .ok_or(NativeHostReadJobError::InvalidConfirmation)?
                    .seek(std::io::SeekFrom::Start(offset))
                    .map_err(|_| NativeHostReadJobError::ReadFailed)?;
                self.current_offset = offset;
            }
        }
        self.awaiting_confirmation = None;
        Ok(())
    }

    pub(crate) fn poll(&mut self) -> Result<NativeHostReadJobStep, NativeHostReadJobError> {
        if !self.is_current() {
            return Err(NativeHostReadJobError::Unavailable);
        }
        if self.awaiting_confirmation.is_some() {
            return Ok(NativeHostReadJobStep::WaitingForConfirmation);
        }
        loop {
            if self.next_file_num >= self.entries.len() {
                return Ok(NativeHostReadJobStep::Done {
                    file_num: i32::try_from(self.next_file_num)
                        .map_err(|_| NativeHostReadJobError::InvalidFileNumber)?,
                });
            }
            if self.current_file.is_none() {
                let file = self
                    .owner
                    .open_read_file(&self.entries[self.next_file_num])
                    .map_err(native_host_read_job_error)?;
                self.current_file = Some(file);
                self.current_offset = 0;
                if self.overwrite_detection {
                    self.awaiting_confirmation = Some(self.next_file_num);
                    return Ok(NativeHostReadJobStep::Digest {
                        file_num: i32::try_from(self.next_file_num)
                            .map_err(|_| NativeHostReadJobError::InvalidFileNumber)?,
                        file_size: self.entries[self.next_file_num].size(),
                        modified_time: self.entries[self.next_file_num].modified_time(),
                    });
                }
            }

            let mut data = vec![0_u8; hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES];
            let mut read_bytes = 0_usize;
            while read_bytes < data.len() {
                let count = self
                    .current_file
                    .as_mut()
                    .ok_or(NativeHostReadJobError::ReadFailed)?
                    .read(&mut data[read_bytes..])
                    .map_err(|_| NativeHostReadJobError::ReadFailed)?;
                if count == 0 {
                    break;
                }
                read_bytes = read_bytes
                    .checked_add(count)
                    .ok_or(NativeHostReadJobError::ReadFailed)?;
            }
            data.truncate(read_bytes);
            if data.is_empty() {
                let file = self
                    .current_file
                    .take()
                    .ok_or(NativeHostReadJobError::ReadFailed)?;
                if self.current_offset != self.entries[self.next_file_num].size() {
                    return Err(NativeHostReadJobError::SnapshotChanged);
                }
                self.owner
                    .verify_read_file(&file, &self.entries[self.next_file_num])
                    .map_err(native_host_read_job_error)?;
                self.current_offset = 0;
                self.next_file_num = self
                    .next_file_num
                    .checked_add(1)
                    .ok_or(NativeHostReadJobError::InvalidFileNumber)?;
                continue;
            }
            let next_offset = self
                .current_offset
                .checked_add(data.len() as u64)
                .ok_or(NativeHostReadJobError::SnapshotChanged)?;
            if next_offset > self.entries[self.next_file_num].size() {
                return Err(NativeHostReadJobError::SnapshotChanged);
            }
            self.current_offset = next_offset;
            let compressed = hbb_common::compress::compress(&data);
            let (data, compressed) = if compressed.len() < data.len() {
                (compressed, true)
            } else {
                (data, false)
            };
            return Ok(NativeHostReadJobStep::Block {
                file_num: i32::try_from(self.next_file_num)
                    .map_err(|_| NativeHostReadJobError::InvalidFileNumber)?,
                data,
                compressed,
            });
        }
    }
}
