//! Stream owned clipboard bytes without handing an image-sized write to GDK.
//! A stalled GIO callback keeps its permit and at most one 64 KiB copied chunk.
use gtk::{gdk, gio, glib, prelude::*, subclass::prelude::*};
use std::{
    cell::{Cell, OnceCell, RefCell},
    future::Future,
    pin::Pin,
    rc::{Rc, Weak},
    time::{Duration, Instant},
};

const CHUNK: usize = 64 * 1024;
const TRANSFERS: usize = 4;
const RETAINED: usize = 2 * farpane_protocol::clipboard::IMAGE_LIMIT;
const IDLE: Duration = Duration::from_secs(3);
const TOTAL: Duration = Duration::from_secs(30);
thread_local! {
    static ACTIVE: Cell<usize> = const { Cell::new(0) };
    static STORAGE: RefCell<Vec<Weak<Storage>>> = const { RefCell::new(Vec::new()) };
}
struct Storage {
    values: Vec<(&'static str, glib::Bytes)>,
    size: usize,
}
struct Permit;
impl Permit {
    fn claim() -> Result<Rc<Self>, glib::Error> {
        ACTIVE.with(|count| {
            if count.get() >= TRANSFERS {
                return Err(error(gio::IOErrorEnum::Busy, "Clipboard readers are busy"));
            }
            count.set(count.get() + 1);
            Ok(Rc::new(Self))
        })
    }
}
impl Drop for Permit {
    fn drop(&mut self) {
        ACTIVE.with(|count| count.set(count.get() - 1));
    }
}
fn error(code: gio::IOErrorEnum, message: &str) -> glib::Error {
    glib::Error::new(code, message)
}

mod imp {
    use super::*;
    #[derive(Default)]
    pub struct Provider {
        pub(super) storage: OnceCell<Rc<Storage>>,
    }
    #[glib::object_subclass]
    impl ObjectSubclass for Provider {
        const NAME: &'static str = "FarPaneClipboardBytes";
        type Type = super::Provider;
        type ParentType = gdk::ContentProvider;
    }
    impl ObjectImpl for Provider {}
    impl ContentProviderImpl for Provider {
        fn formats(&self) -> gdk::ContentFormats {
            let names: Vec<_> = self
                .storage
                .get()
                .unwrap()
                .values
                .iter()
                .map(|v| v.0)
                .collect();
            gdk::ContentFormats::new(&names)
        }
        fn storable_formats(&self) -> gdk::ContentFormats {
            self.formats()
        }
        fn write_mime_type_future(
            &self,
            mime: &str,
            stream: &gio::OutputStream,
            priority: glib::Priority,
        ) -> Pin<Box<dyn Future<Output = Result<(), glib::Error>> + 'static>> {
            let storage = self.storage.get().unwrap().clone();
            let index = storage.values.iter().position(|v| v.0 == mime);
            let stream = stream.clone();
            Box::pin(async move {
                let index = index.ok_or_else(|| {
                    error(
                        gio::IOErrorEnum::NotSupported,
                        "Unsupported clipboard format",
                    )
                })?;
                let permit = Permit::claim()?;
                let bytes = &storage.values[index].1;
                let deadline = Instant::now() + TOTAL;
                for chunk in bytes.chunks(CHUNK) {
                    let remaining = deadline.saturating_duration_since(Instant::now());
                    if remaining.is_zero() {
                        return Err(error(
                            gio::IOErrorEnum::TimedOut,
                            "Clipboard write timed out",
                        ));
                    }
                    // A GDK callback may survive cancellation. Copy only this
                    // bounded chunk, so it cannot retain the full shared memfd.
                    let chunk = chunk.to_vec();
                    let size = chunk.len();
                    let write_permit = permit.clone();
                    let write = gio::GioFuture::new(&stream, move |stream, cancel, done| {
                        stream.write_all_async(chunk, priority, Some(cancel), move |result| {
                            let _permit = write_permit;
                            done.resolve(result);
                        });
                    });
                    let step = async move {
                        let (_, written, issue) = write.await.map_err(|(_, issue)| issue)?;
                        if let Some(issue) = issue {
                            return Err(issue);
                        }
                        if written != size {
                            return Err(error(
                                gio::IOErrorEnum::Failed,
                                "Incomplete clipboard write",
                            ));
                        }
                        // GDK flushes at its request-size threshold and closes
                        // after this provider completes. Explicit flush_async
                        // during INCR can hit a GDK pending-task result-type
                        // mismatch; keep the regular write/close contract.
                        Ok(())
                    };
                    glib::future_with_timeout(remaining.min(IDLE), step)
                        .await
                        .map_err(|_| {
                            error(
                                gio::IOErrorEnum::TimedOut,
                                "Clipboard reader stopped responding",
                            )
                        })??;
                }
                Ok(())
            })
        }
    }
}
glib::wrapper! {
    pub struct Provider(ObjectSubclass<imp::Provider>) @extends gdk::ContentProvider;
}
/// Aliases share Bytes; `size` counts the original bundle once, not each alias.
pub fn new(
    values: Vec<(&'static str, glib::Bytes)>,
    size: usize,
) -> Result<gdk::ContentProvider, ()> {
    let storage = STORAGE.with(|registry| {
        let mut registry = registry.borrow_mut();
        registry.retain(|value| value.strong_count() > 0);
        let retained: usize = registry
            .iter()
            .filter_map(Weak::upgrade)
            .map(|value| value.size)
            .sum();
        if size == 0 || size > RETAINED || retained > RETAINED - size {
            return Err(());
        }
        let storage = Rc::new(Storage { values, size });
        registry.push(Rc::downgrade(&storage));
        Ok(storage)
    })?;
    let provider: Provider = glib::Object::new();
    provider.imp().storage.set(storage).map_err(|_| ())?;
    Ok(provider.upcast())
}

#[cfg(test)]
pub(crate) async fn verify_streaming_limits() {
    use std::os::fd::FromRawFd;
    let data = glib::Bytes::from_owned(vec![b'x'; CHUNK * 4]);
    let provider = new(vec![("text/html", data.clone())], data.len()).unwrap();
    let output = gio::MemoryOutputStream::new_resizable();
    provider
        .write_mime_type_future("text/html", &output, glib::Priority::DEFAULT)
        .await
        .unwrap();
    output.close(gio::Cancellable::NONE).unwrap();
    assert_eq!(output.steal_as_bytes(), data);
    assert_eq!(ACTIVE.with(Cell::get), 0);
    let mut readers = Vec::new();
    let mut tasks = Vec::new();
    for _ in 0..TRANSFERS {
        let mut pipe = [-1; 2];
        assert_eq!(
            unsafe { libc::pipe2(pipe.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) },
            0
        );
        readers.push(unsafe { std::os::fd::OwnedFd::from_raw_fd(pipe[0]) });
        let output =
            gio::UnixOutputStream::take_fd(unsafe { std::os::fd::OwnedFd::from_raw_fd(pipe[1]) });
        let provider = provider.clone();
        tasks.push(glib::MainContext::default().spawn_local(async move {
            provider
                .write_mime_type_future("text/html", &output, glib::Priority::DEFAULT)
                .await
        }));
    }
    let until = Instant::now() + Duration::from_secs(1);
    while ACTIVE.with(Cell::get) < TRANSFERS {
        assert!(Instant::now() < until);
        glib::timeout_future(Duration::from_millis(10)).await;
    }
    let busy = provider
        .write_mime_type_future(
            "text/html",
            &gio::MemoryOutputStream::new_resizable(),
            glib::Priority::DEFAULT,
        )
        .await
        .unwrap_err();
    assert_eq!(
        busy.kind::<gio::IOErrorEnum>(),
        Some(gio::IOErrorEnum::Busy)
    );
    for task in tasks {
        let result = glib::future_with_timeout(Duration::from_secs(5), task)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            result.unwrap_err().kind::<gio::IOErrorEnum>(),
            Some(gio::IOErrorEnum::TimedOut)
        );
    }
    drop(readers);
    let until = Instant::now() + Duration::from_secs(1);
    while ACTIVE.with(Cell::get) != 0 {
        assert!(Instant::now() < until);
        glib::timeout_future(Duration::from_millis(10)).await;
    }
    let recovered = gio::MemoryOutputStream::new_resizable();
    provider
        .write_mime_type_future("text/html", &recovered, glib::Priority::DEFAULT)
        .await
        .unwrap();
    recovered.close(gio::Cancellable::NONE).unwrap();
    assert_eq!(recovered.steal_as_bytes(), data);
    println!("PASS: actual GIO byte output, four blocked pipes, fifth rejected, timeout cancellation and recovery");
}
