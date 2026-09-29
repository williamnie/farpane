#[cfg(target_os = "macos")]
#[derive(Debug)]
pub(crate) struct NativeHostWriteJob {
    id: i32,
    owner: Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>,
    _reservations: rdn_host_file_transfer::NativeHostWriteReservations,
    entries: Vec<NativeHostPreparedWriteEntry>,
    current: Option<(usize, NativeHostWriteFile)>,
    next_file_num: usize,
    expected_total_size: u64,
    written_total_size: u64,
    skipped_total_size: u64,
    overwrite_detection: bool,
    awaiting_existing_target: Option<usize>,
}

#[cfg(target_os = "macos")]
impl NativeHostWriteJob {
    pub(crate) fn id(&self) -> i32 {
        self.id
    }

    pub(crate) fn is_current(&self) -> bool {
        let broker = MEDIA_BROKER.lock().unwrap();
        broker.binding.is_some()
            && broker
                .file_service_owner
                .as_ref()
                .is_some_and(|owner| Arc::ptr_eq(owner, &self.owner))
    }

    pub(crate) fn confirm_file_digest(
        &mut self,
        file_num: i32,
        file_size: u64,
        last_modified: u64,
        is_resume: bool,
    ) -> Result<NativeHostWriteDigestDecision, NativeHostWriteJobError> {
        if !self.is_current() {
            return Err(NativeHostWriteJobError::Unavailable);
        }
        if !self.overwrite_detection {
            return Err(NativeHostWriteJobError::DigestMismatch);
        }
        let file_num =
            usize::try_from(file_num).map_err(|_| NativeHostWriteJobError::UnexpectedFileNumber)?;
        if file_num != self.next_file_num || file_num >= self.entries.len() {
            return Err(NativeHostWriteJobError::UnexpectedFileNumber);
        }
        if self.awaiting_existing_target.is_some() {
            return Err(NativeHostWriteJobError::ExistingTargetDecisionRequired);
        }
        if let Some((current_num, current)) = self.current.as_ref() {
            if *current_num + 1 != file_num || current.written_size != current.expected_size {
                return Err(NativeHostWriteJobError::UnexpectedFileNumber);
            }
        }
        let entry = &self.entries[file_num];
        if entry.expected_size != file_size || entry.modified_time != last_modified {
            return Err(NativeHostWriteJobError::DigestMismatch);
        }
        let existing = self
            .owner
            .try_open_existing_file_for_digest(&entry.destination_path)
            .map_err(|_| NativeHostWriteJobError::ExistingTargetUnsafe)?;
        if let Some(existing) = existing {
            let metadata = existing
                .metadata()
                .map_err(|_| NativeHostWriteJobError::ExistingTargetUnsafe)?;
            let existing_modified = metadata
                .modified()
                .map_err(|_| NativeHostWriteJobError::ExistingTargetUnsafe)?
                .duration_since(UNIX_EPOCH)
                .map_err(|_| NativeHostWriteJobError::ExistingTargetUnsafe)?
                .as_secs();
            let existing_size = metadata.len();
            self.awaiting_existing_target = Some(file_num);
            return Ok(NativeHostWriteDigestDecision::ExistingTarget {
                file_size: existing_size,
                last_modified: existing_modified,
                is_identical: existing_size == file_size && existing_modified == last_modified,
            });
        }
        if !is_resume && entry.expected_size == 0 {
            if let Some((current_num, current)) = self.current.take() {
                if current_num + 1 != file_num || current.written_size != current.expected_size {
                    self.current = Some((current_num, current));
                    return Err(NativeHostWriteJobError::UnexpectedFileNumber);
                }
                current.commit()?;
            }
            NativeHostWriteFile::create(self.owner.clone(), entry)?.commit()?;
            self.next_file_num = file_num
                .checked_add(1)
                .ok_or(NativeHostWriteJobError::UnexpectedFileNumber)?;
            return Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0));
        }
        if !is_resume {
            return Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0));
        }
        if self.entries.len() != 1 || entry.expected_size > u32::MAX as u64 {
            return Err(NativeHostWriteJobError::ResumeUnsupported);
        }
        let resumed = match NativeHostWriteFile::resume(self.owner.clone(), entry) {
            Ok(resumed) => resumed,
            Err(error) => {
                let _ = self.owner.remove_file(&entry.staging_path);
                return Err(error);
            }
        };
        let Some(resumed) = resumed else {
            return Ok(NativeHostWriteDigestDecision::ConfirmedOffset(0));
        };
        let offset = u32::try_from(resumed.written_size)
            .map_err(|_| NativeHostWriteJobError::ResumeUnsupported)?;
        self.written_total_size = resumed.written_size;
        self.current = Some((file_num, resumed));
        self.next_file_num = file_num + 1;
        Ok(NativeHostWriteDigestDecision::ConfirmedOffset(offset))
    }

    pub(crate) fn confirm_existing_target_decision(
        &mut self,
        file_num: i32,
        decision: NativeHostExistingTargetDecision,
    ) -> Result<(), NativeHostWriteJobError> {
        if !self.is_current() {
            return Err(NativeHostWriteJobError::Unavailable);
        }
        let file_num =
            usize::try_from(file_num).map_err(|_| NativeHostWriteJobError::UnexpectedFileNumber)?;
        if self.awaiting_existing_target != Some(file_num)
            || file_num != self.next_file_num
            || file_num >= self.entries.len()
        {
            return Err(NativeHostWriteJobError::UnexpectedFileNumber);
        }
        match decision {
            NativeHostExistingTargetDecision::Skip => {}
            NativeHostExistingTargetDecision::Replace { offset } => {
                let _ = offset;
                return Err(NativeHostWriteJobError::ExistingTargetReplacementUnsupported);
            }
        }
        if let Some((current_num, current)) = self.current.take() {
            if current_num + 1 != file_num || current.written_size != current.expected_size {
                self.current = Some((current_num, current));
                return Err(NativeHostWriteJobError::UnexpectedFileNumber);
            }
            current.commit()?;
        }
        self.owner
            .remove_file_if_exists(&self.entries[file_num].staging_path)
            .map_err(|_| NativeHostWriteJobError::ExistingTargetUnsafe)?;
        self.skipped_total_size = self
            .skipped_total_size
            .checked_add(self.entries[file_num].expected_size)
            .ok_or(NativeHostWriteJobError::TotalSizeMismatch)?;
        self.next_file_num = file_num
            .checked_add(1)
            .ok_or(NativeHostWriteJobError::UnexpectedFileNumber)?;
        self.awaiting_existing_target = None;
        Ok(())
    }

    pub(crate) fn write_block(
        &mut self,
        file_num: i32,
        data: &[u8],
        compressed: bool,
    ) -> Result<(), NativeHostWriteJobError> {
        if !self.is_current() {
            return Err(NativeHostWriteJobError::Unavailable);
        }
        if data.len() > hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES {
            return Err(NativeHostWriteJobError::WirePayloadTooLarge);
        }
        let payload = if compressed {
            hbb_common::compress::decompress_with_limit(
                data,
                hbb_common::fs::MAX_FILE_TRANSFER_BLOCK_BYTES,
            )
            .map_err(|_| NativeHostWriteJobError::DecodedPayloadInvalidOrTooLarge)?
        } else {
            data.to_vec()
        };
        let file_num =
            usize::try_from(file_num).map_err(|_| NativeHostWriteJobError::UnexpectedFileNumber)?;
        if self.awaiting_existing_target.is_some() {
            return Err(NativeHostWriteJobError::ExistingTargetDecisionRequired);
        }
        if file_num >= self.entries.len() {
            return Err(NativeHostWriteJobError::UnexpectedFileNumber);
        }

        let needs_new_file = self
            .current
            .as_ref()
            .map_or(true, |(current_num, _)| *current_num != file_num);
        if needs_new_file {
            if file_num != self.next_file_num {
                return Err(NativeHostWriteJobError::UnexpectedFileNumber);
            }
            if let Some((current_num, current)) = self.current.take() {
                current.commit()?;
                self.next_file_num = current_num
                    .checked_add(1)
                    .ok_or(NativeHostWriteJobError::UnexpectedFileNumber)?;
            }
            if file_num != self.next_file_num {
                return Err(NativeHostWriteJobError::UnexpectedFileNumber);
            }
            let current = NativeHostWriteFile::create(self.owner.clone(), &self.entries[file_num])?;
            self.current = Some((file_num, current));
            self.next_file_num = file_num
                .checked_add(1)
                .ok_or(NativeHostWriteJobError::UnexpectedFileNumber)?;
        }

        let next_total = self
            .written_total_size
            .checked_add(payload.len() as u64)
            .ok_or(NativeHostWriteJobError::TotalSizeMismatch)?;
        self.current
            .as_mut()
            .ok_or(NativeHostWriteJobError::Storage)?
            .1
            .write_payload(&payload)?;
        if next_total > self.expected_total_size {
            return Err(NativeHostWriteJobError::TotalSizeMismatch);
        }
        self.written_total_size = next_total;
        Ok(())
    }

    pub(crate) fn finish(mut self, file_num: i32) -> Result<(), NativeHostWriteJobError> {
        let result = self.finish_inner(file_num);
        if result.is_err() {
            self.abort_in_place();
        }
        result
    }

    fn finish_inner(&mut self, file_num: i32) -> Result<(), NativeHostWriteJobError> {
        if !self.is_current() {
            return Err(NativeHostWriteJobError::Unavailable);
        }
        let done_file_num =
            usize::try_from(file_num).map_err(|_| NativeHostWriteJobError::UnexpectedFileNumber)?;
        if done_file_num != self.entries.len()
            || self.awaiting_existing_target.is_some()
            || self
                .written_total_size
                .checked_add(self.skipped_total_size)
                .ok_or(NativeHostWriteJobError::TotalSizeMismatch)?
                != self.expected_total_size
        {
            return Err(NativeHostWriteJobError::TotalSizeMismatch);
        }
        if let Some((current_num, current)) = self.current.take() {
            if current_num + 1 != self.entries.len() {
                return Err(NativeHostWriteJobError::UnexpectedFileNumber);
            }
            current.commit()?;
        } else if self.next_file_num != self.entries.len() {
            return Err(NativeHostWriteJobError::FileSizeMismatch);
        }
        self.next_file_num = self.entries.len();
        Ok(())
    }

    pub(crate) fn abort(mut self) {
        self.abort_in_place();
    }

    fn abort_in_place(&mut self) {
        if let Some((_, mut current)) = self.current.take() {
            current.preserve_for_resume = false;
        }
    }
}
