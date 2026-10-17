//! Selected upload sources and incremental manifests. Never read a whole tree.
use super::{
    batch::{Step, Walker},
    *,
};
use std::{collections::HashSet, path::PathBuf, task::Poll};

pub struct Batch {
    pub entries: Vec<Entry>,
    pub more: bool,
    pub skipped: u64,
}
enum Origin {
    Single(Option<Reader>),
    Files(Vec<(String, PathBuf)>),
    Tree(Arc<Source>, Walker),
    Shared(Arc<Root>, String, Walker),
}
pub struct Plan {
    origin: Origin,
    pending: Vec<Entry>,
    carry: Option<Entry>,
    ended: bool,
    pub tree: bool,
}
impl Plan {
    pub fn file(path: &Path, name: &str) -> io::Result<Self> {
        validate_relative(name, false)?;
        let reader = Reader::selected(path)?;
        let entry = Entry {
            name: name.into(),
            directory: false,
            size: reader.size(),
            modified: reader.modified(),
        };
        Ok(Self {
            origin: Origin::Single(Some(reader)),
            pending: vec![entry],
            carry: None,
            ended: true,
            tree: false,
        })
    }
    pub fn files(paths: &[PathBuf]) -> io::Result<Self> {
        if paths.is_empty()
            || paths.len() > PAGE_ENTRIES
            || paths
                .iter()
                .map(|p| p.as_os_str().len() + 64)
                .sum::<usize>()
                > PAGE_BYTES
        {
            return Err(invalid("Selected files exceed the bounded selection limit"));
        }
        let mut names = HashSet::new();
        let mut selected = Vec::new();
        let mut entries = Vec::new();
        for path in paths {
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .ok_or_else(|| invalid("Invalid selected filename"))?;
            validate_relative(name, false)?;
            if !names.insert(name.to_owned()) {
                return Err(invalid("Selected filenames collide at destination"));
            }
            let reader = Reader::selected(path)?;
            entries.push(Entry {
                name: name.into(),
                directory: false,
                size: reader.size(),
                modified: reader.modified(),
            });
            selected.push((name.into(), path.clone()));
        }
        Ok(Self {
            origin: Origin::Files(selected),
            pending: entries,
            carry: None,
            ended: true,
            tree: false,
        })
    }
    pub fn folder(path: &Path) -> io::Result<Self> {
        let source = Arc::new(Source::selected(path)?);
        let walker = source.clone().walk(true)?;
        // The empty name is the explicit selected folder itself. The wire owner
        // must prefix it with its nonempty, immutable destination tree root.
        let root = Entry {
            name: String::new(),
            directory: true,
            size: 0,
            modified: 0,
        };
        Ok(Self {
            origin: Origin::Tree(source, walker),
            pending: vec![root],
            carry: None,
            ended: false,
            tree: true,
        })
    }
    /// Retain the private shared-root authority; never reopen it as a relaxed
    /// user-selected source. Every cursor and reader rechecks that authority.
    pub fn shared_folder(root: Arc<Root>, path: &str) -> io::Result<Self> {
        let walker = root.clone().walk(path, true)?;
        Ok(Self {
            origin: Origin::Shared(root, path.into(), walker),
            pending: vec![Entry {
                name: String::new(),
                directory: true,
                size: 0,
                modified: 0,
            }],
            carry: None,
            ended: false,
            tree: true,
        })
    }
    /// One bounded walker step per call, so the session owner can service cancel
    /// and revoke between scans. Keep at most one batch plus one lookahead entry.
    pub fn poll_batch(&mut self) -> io::Result<Poll<Option<Batch>>> {
        if self.ended {
            return Ok(Poll::Ready(self.take_batch(false)));
        }
        let next = if let Some(entry) = self.carry.take() {
            Some(entry)
        } else {
            let walker = match &mut self.origin {
                Origin::Tree(_, walker) | Origin::Shared(_, _, walker) => walker,
                _ => unreachable!(),
            };
            match walker.step()? {
                Step::Entry(entry) => Some(entry),
                Step::Yield => return Ok(Poll::Pending),
                Step::Done => {
                    self.ended = true;
                    None
                }
            }
        };
        if let Some(entry) = next {
            let bytes: usize = self.pending.iter().map(|e| e.name.len() + 64).sum();
            if self.pending.len() == PAGE_ENTRIES || bytes + entry.name.len() + 64 > PAGE_BYTES {
                self.carry = Some(entry);
                return Ok(Poll::Ready(self.take_batch(true)));
            }
            self.pending.push(entry);
        }
        if self.ended {
            Ok(Poll::Ready(self.take_batch(false)))
        } else {
            Ok(Poll::Pending)
        }
    }
    fn take_batch(&mut self, more: bool) -> Option<Batch> {
        if self.pending.is_empty() {
            return None;
        }
        let skipped = match &self.origin {
            Origin::Tree(_, w) | Origin::Shared(_, _, w) => w.skipped,
            _ => 0,
        };
        Some(Batch {
            entries: std::mem::take(&mut self.pending),
            more,
            skipped,
        })
    }
    pub fn open(&mut self, entry: &Entry) -> io::Result<Reader> {
        if entry.directory {
            return Err(invalid("Directories do not have file blocks"));
        }
        let reader = match &mut self.origin {
            Origin::Single(reader) => reader
                .take()
                .ok_or_else(|| invalid("Selected file was already read"))?,
            Origin::Files(paths) => {
                let (_, path) = paths
                    .iter()
                    .find(|(name, _)| name == &entry.name)
                    .ok_or_else(|| invalid("File was not selected"))?;
                Reader::selected(path)?
            }
            Origin::Tree(source, _) => source.read(&entry.name)?,
            Origin::Shared(root, base, _) => root.read(&batch::scoped(base, &entry.name))?,
        };
        if reader.size() != entry.size || reader.modified() != entry.modified {
            return Err(invalid("Selected source changed after its manifest"));
        }
        Ok(reader)
    }
}
