//! Per-connection transfer ownership. Call only on the file I/O thread.
//! Network adapters must authenticate first, map wire IDs to these local keys,
//! and deliver local confirmation separately from peer messages.
use super::{batch::Incoming, *};
use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};

pub const MAX_JOBS: usize = 8;
const IDLE_LIMIT: Duration = Duration::from_secs(120);
const CONSENT_LIMIT: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Key {
    pub generation: u64,
    pub serial: u64,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cursor {
    pub key: Key,
    pub page: u32,
}
#[derive(Debug)]
pub struct Page {
    pub entries: Vec<Entry>,
    pub next: Option<Cursor>,
    pub skipped: u64,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Progress {
    pub done: u64,
    pub total: u64,
    pub complete: bool,
}
#[derive(Debug)]
pub enum Read {
    Block(Vec<u8>),
    End,
}
struct Receiving {
    batch: Incoming,
    confirmed: bool,
    overwrite: bool,
}
struct Sending {
    reader: Reader,
    confirmed: bool,
}
enum Job {
    Receive(Receiving),
    Send(Sending),
}
struct Active {
    job: Job,
    touched: Instant,
}
struct Listing {
    cursor: Cursor,
    path: String,
    hidden: bool,
    directory: Directory,
    touched: Instant,
}

pub struct Owner {
    root: Arc<Root>,
    generation: u64,
    serial: u64,
    revoked: bool,
    jobs: HashMap<Key, Active>,
    listing: Option<Listing>,
}
impl Owner {
    pub fn new(root: Arc<Root>, generation: u64) -> io::Result<Self> {
        if generation == 0 || root.selected_read {
            return Err(invalid("Invalid transfer authority"));
        }
        root.check()?;
        Ok(Self {
            root,
            generation,
            serial: 0,
            revoked: false,
            jobs: HashMap::new(),
            listing: None,
        })
    }
    fn check(&self) -> io::Result<()> {
        if self.revoked {
            return Err(denied("File permission was revoked"));
        }
        self.root.check()
    }
    fn key(&mut self) -> io::Result<Key> {
        self.serial = self
            .serial
            .checked_add(1)
            .ok_or_else(|| invalid("File key exhausted"))?;
        Ok(Key {
            generation: self.generation,
            serial: self.serial,
        })
    }
    fn capacity(&self) -> io::Result<()> {
        self.check()?;
        if self.jobs.len() >= MAX_JOBS {
            return Err(invalid("Too many active file jobs"));
        }
        Ok(())
    }
    /// No destination file/directory is created until confirmation and begin.
    pub fn offer_receive(&mut self, entries: Vec<Entry>) -> io::Result<(Key, u64)> {
        self.capacity()?;
        let batch = Incoming::new(self.root.clone(), entries)?;
        let total = batch.progress().1;
        let key = self.key()?;
        self.jobs.insert(
            key,
            Active {
                job: Job::Receive(Receiving {
                    batch,
                    confirmed: false,
                    overwrite: false,
                }),
                touched: Instant::now(),
            },
        );
        Ok((key, total))
    }
    /// A peer's digest/confirm message must never call this local-consent method.
    pub fn confirm_receive(&mut self, key: Key, accept: bool, overwrite: bool) -> io::Result<()> {
        self.check()?;
        let active = self
            .jobs
            .get_mut(&key)
            .ok_or_else(|| invalid("Unknown file job"))?;
        let Job::Receive(job) = &mut active.job else {
            return Err(invalid("Not a receive job"));
        };
        if job.confirmed {
            return Err(invalid("File decision already consumed"));
        }
        if !accept {
            self.jobs.remove(&key);
            return Ok(());
        }
        job.confirmed = true;
        job.overwrite = overwrite;
        active.touched = Instant::now();
        Ok(())
    }
    fn receiving<F>(&mut self, key: Key, action: F) -> io::Result<Progress>
    where
        F: FnOnce(&mut Receiving) -> io::Result<()>,
    {
        self.check()?;
        // Remove while operating: any disk/protocol failure drops the partial
        // writer and cannot leave a failed job able to accept further blocks.
        let mut active = self
            .jobs
            .remove(&key)
            .ok_or_else(|| invalid("Unknown file job"))?;
        let Job::Receive(job) = &mut active.job else {
            return Err(invalid("Not a receive job"));
        };
        if !job.confirmed {
            return Err(denied("Destination has not been confirmed"));
        }
        action(job)?;
        let (done, total) = job.batch.progress();
        let complete = job.batch.complete();
        if !complete {
            active.touched = Instant::now();
            self.jobs.insert(key, active);
        }
        Ok(Progress {
            done,
            total,
            complete,
        })
    }
    pub fn begin_receive(&mut self, key: Key, index: usize) -> io::Result<Progress> {
        self.receiving(key, |job| job.batch.begin(index, job.overwrite))
    }
    pub fn write(&mut self, key: Key, index: usize, data: &[u8]) -> io::Result<Progress> {
        self.receiving(key, |job| job.batch.write(index, data))
    }
    pub fn commit(&mut self, key: Key, index: usize) -> io::Result<Progress> {
        self.receiving(key, |job| job.batch.commit(index))
    }
    /// Metadata/open only; no content is read until local policy confirms.
    pub fn offer_send(&mut self, path: &str) -> io::Result<(Key, u64)> {
        self.capacity()?;
        let reader = self.root.read(path)?;
        let total = reader.size();
        let key = self.key()?;
        self.jobs.insert(
            key,
            Active {
                job: Job::Send(Sending {
                    reader,
                    confirmed: false,
                }),
                touched: Instant::now(),
            },
        );
        Ok((key, total))
    }
    pub fn confirm_send(&mut self, key: Key, accept: bool) -> io::Result<()> {
        self.check()?;
        let active = self
            .jobs
            .get_mut(&key)
            .ok_or_else(|| invalid("Unknown file job"))?;
        let Job::Send(job) = &mut active.job else {
            return Err(invalid("Not a send job"));
        };
        if job.confirmed {
            return Err(invalid("File decision already consumed"));
        }
        if !accept {
            self.jobs.remove(&key);
            return Ok(());
        }
        job.confirmed = true;
        active.touched = Instant::now();
        Ok(())
    }
    /// EOF means only that the source has been read, not that the peer saved it.
    /// The network owner must wait for the peer's completion acknowledgement.
    pub fn read(&mut self, key: Key) -> io::Result<Read> {
        self.check()?;
        let mut active = self
            .jobs
            .remove(&key)
            .ok_or_else(|| invalid("Unknown file job"))?;
        let Job::Send(job) = &mut active.job else {
            return Err(invalid("Not a send job"));
        };
        if !job.confirmed {
            return Err(denied("Source has not been confirmed"));
        }
        let block = job.reader.read_block()?;
        if block.is_empty() {
            return Ok(Read::End);
        }
        active.touched = Instant::now();
        self.jobs.insert(key, active);
        Ok(Read::Block(block))
    }
    /// One descriptor cursor per connection. Continuations are single-use and
    /// bound to path, generation, hidden-file policy and the exact next page.
    pub fn list(&mut self, path: &str, hidden: bool, after: Option<Cursor>) -> io::Result<Page> {
        self.check()?;
        validate_relative(path, true)?;
        let mut listing = if let Some(cursor) = after {
            let old = self
                .listing
                .as_ref()
                .ok_or_else(|| invalid("Directory cursor expired"))?;
            if old.cursor != cursor || old.path != path || old.hidden != hidden {
                return Err(invalid("Directory cursor does not match this request"));
            }
            self.listing.take().unwrap()
        } else {
            self.listing = None;
            Listing {
                cursor: Cursor {
                    key: self.key()?,
                    page: 0,
                },
                path: path.into(),
                hidden,
                directory: self.root.list(path, hidden)?,
                touched: Instant::now(),
            }
        };
        let (entries, more) = listing.directory.page()?;
        let skipped = listing.directory.skipped;
        let next = if more {
            listing.cursor.page = listing
                .cursor
                .page
                .checked_add(1)
                .ok_or_else(|| invalid("Directory page exhausted"))?;
            listing.touched = Instant::now();
            let next = listing.cursor;
            self.listing = Some(listing);
            Some(next)
        } else {
            None
        };
        Ok(Page {
            entries,
            next,
            skipped,
        })
    }
    pub fn cancel(&mut self, key: Key) -> io::Result<()> {
        self.check()?;
        self.jobs
            .remove(&key)
            .ok_or_else(|| invalid("Unknown file job"))?;
        Ok(())
    }
    /// Called when an authenticated session ends or its file/root policy changes.
    /// Revocation is permanent: a later grant needs a new owner/generation.
    pub fn revoke(&mut self) {
        self.revoked = true;
        self.jobs.clear();
        self.listing = None;
    }
    pub fn active_jobs(&self) -> usize {
        self.jobs.len()
    }
    /// The event loop calls this even when no peer messages arrive. Returns the
    /// local keys to fail at the protocol/UI boundary, without retaining history.
    pub fn expire(&mut self, now: Instant) -> Vec<Key> {
        let mut expired = Vec::new();
        self.jobs.retain(|key, active| {
            let confirmed = match &active.job {
                Job::Receive(j) => j.confirmed,
                Job::Send(j) => j.confirmed,
            };
            let keep = now.saturating_duration_since(active.touched)
                < if confirmed { IDLE_LIMIT } else { CONSENT_LIMIT };
            if !keep {
                expired.push(*key);
            }
            keep
        });
        if self
            .listing
            .as_ref()
            .is_some_and(|l| now.saturating_duration_since(l.touched) >= IDLE_LIMIT)
        {
            self.listing = None;
        }
        expired
    }
}
