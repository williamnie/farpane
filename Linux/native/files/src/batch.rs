//! Streaming folder traversal and bounded receive batches. Wire/session owners
//! must retain their own permission, confirmation and generation authority.
use super::*;
use std::sync::Arc;

pub const BATCH_ENTRIES: usize = 128;
pub struct Walker {
    source: WalkSource,
    stack: Vec<(String, Directory)>,
    hidden: bool,
    pub skipped: u64,
}
enum WalkSource {
    Selected(Arc<Source>),
    Shared(Arc<Root>, String),
}
impl WalkSource {
    fn list(&self, path: &str, hidden: bool) -> io::Result<Directory> {
        match self {
            Self::Selected(source) => source.list(path, hidden),
            Self::Shared(root, base) => root.list(&scoped(base, path), hidden),
        }
    }
}
pub(crate) fn scoped(base: &str, path: &str) -> String {
    if path.is_empty() {
        base.into()
    } else {
        format!("{base}/{path}")
    }
}
pub enum Step {
    Entry(Entry),
    Yield,
    Done,
}
impl Source {
    pub fn walk(self: Arc<Self>, hidden: bool) -> io::Result<Walker> {
        let first = self.list("", hidden)?;
        Ok(Walker {
            source: WalkSource::Selected(self),
            stack: vec![(String::new(), first)],
            hidden,
            skipped: 0,
        })
    }
}
impl Root {
    pub fn walk(self: Arc<Self>, path: &str, hidden: bool) -> io::Result<Walker> {
        validate_relative(path, false)?;
        let first = self.list(path, hidden)?;
        Ok(Walker {
            source: WalkSource::Shared(self, path.into()),
            stack: vec![(String::new(), first)],
            hidden,
            skipped: 0,
        })
    }
}
impl Walker {
    /// A traversal retains directory cursors, not a recursive manifest. One call
    /// examines at most 4096 directory entries, including unsupported objects.
    pub fn step(&mut self) -> io::Result<Step> {
        let mut budget = 4096;
        loop {
            let Some((prefix, dir)) = self.stack.last_mut() else {
                return Ok(Step::Done);
            };
            let before = dir.skipped;
            let entry = dir.next(&mut budget)?;
            self.skipped += dir.skipped - before;
            let Some(mut entry) = entry else {
                if !dir.ended {
                    return Ok(Step::Yield);
                }
                self.stack.pop();
                continue;
            };
            if !prefix.is_empty() {
                entry.name = format!("{prefix}/{}", entry.name);
            }
            validate_relative(&entry.name, false)?;
            if entry.directory {
                if self.stack.len() >= 64 {
                    return Err(invalid("Folder nesting exceeds transfer limit"));
                }
                let dir = self.source.list(&entry.name, self.hidden)?;
                self.stack.push((entry.name.clone(), dir));
            }
            return Ok(Step::Entry(entry));
        }
    }
}

pub struct Incoming {
    root: Arc<Root>,
    entries: Vec<Entry>,
    next: usize,
    active: Option<Writer>,
    done: u64,
    total: u64,
}
impl Incoming {
    pub fn new(root: Arc<Root>, entries: Vec<Entry>) -> io::Result<Self> {
        if entries.is_empty() || entries.len() > BATCH_ENTRIES {
            return Err(invalid("Invalid file batch length"));
        }
        let mut names = std::collections::HashMap::new();
        let mut bytes = 0;
        let mut total = 0u64;
        for e in &entries {
            validate_relative(&e.name, false)?;
            bytes += e.name.len() + 64;
            if bytes > PAGE_BYTES || names.insert(e.name.as_str(), e.directory).is_some() {
                return Err(invalid("Oversized or duplicate file manifest"));
            }
            if e.directory && e.size != 0 {
                return Err(invalid("Directory has a payload size"));
            }
            total = total
                .checked_add(e.size)
                .filter(|n| *n <= i64::MAX as u64)
                .ok_or_else(|| invalid("File size sum overflows"))?;
        }
        for e in &entries {
            let mut path = e.name.as_str();
            while let Some((parent, _)) = path.rsplit_once('/') {
                if names.get(parent) == Some(&false) {
                    return Err(invalid("Manifest file is also used as a directory"));
                }
                path = parent;
            }
        }
        Ok(Self {
            root,
            entries,
            next: 0,
            active: None,
            done: 0,
            total,
        })
    }
    pub fn entries(&self) -> &[Entry] {
        &self.entries
    }
    pub fn progress(&self) -> (u64, u64) {
        (
            self.done + self.active.as_ref().map_or(0, Writer::written),
            self.total,
        )
    }
    /// Called only after the owning UI/session has decided on this destination.
    pub fn begin(&mut self, index: usize, overwrite: bool) -> io::Result<()> {
        if self.active.is_some() || index != self.next {
            return Err(invalid("Unexpected file number"));
        }
        let entry = self
            .entries
            .get(index)
            .ok_or_else(|| invalid("File number outside manifest"))?;
        if entry.directory {
            self.root.create_directories(&entry.name)?;
            self.next += 1;
        } else {
            self.active = Some(self.root.receive(&entry.name, entry.size, overwrite)?);
        }
        Ok(())
    }
    pub fn write(&mut self, index: usize, data: &[u8]) -> io::Result<()> {
        if index != self.next {
            return Err(invalid("File block belongs to another file"));
        }
        self.active
            .as_mut()
            .ok_or_else(|| invalid("No confirmed destination"))?
            .write_block(data)
    }
    pub fn commit(&mut self, index: usize) -> io::Result<()> {
        if index != self.next {
            return Err(invalid("File completion belongs to another file"));
        }
        let writer = self
            .active
            .take()
            .ok_or_else(|| invalid("No confirmed destination"))?;
        writer.finish()?;
        self.done += self.entries[index].size;
        self.next += 1;
        Ok(())
    }
    pub fn complete(&self) -> bool {
        self.active.is_none() && self.next == self.entries.len()
    }
}
