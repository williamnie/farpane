//! GTK-owned EGL context and decoder leases. No GPU lease is ACKed on Drop/HUP.
use crate::viewer_bridge::Frame;
use adw::prelude::*;
use farpane_protocol::{frame, frame_socket::Packet, ImportFormat, Renderer};
use gtk::{gdk, glib};
use std::{
    cell::{Cell, RefCell},
    ffi::{c_char, c_int, c_void, CStr},
    os::fd::AsRawFd,
    ptr::NonNull,
    rc::Rc,
    time::{Duration, Instant},
};

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Format {
    format: u32,
    modifier: u64,
}
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Plane {
    fd: c_int,
    format: u32,
    width: u32,
    height: u32,
    pitch: u32,
    offset: u64,
    modifier: u64,
}
#[repr(C)]
struct Image {
    width: u32,
    height: u32,
    planes: [Plane; 2],
    matrix: c_int,
    range: c_int,
    chroma: c_int,
}
unsafe extern "C" {
    fn fp_gpu_new(error: *mut c_char, capacity: usize) -> *mut c_void;
    fn fp_gpu_formats(gpu: *const c_void, formats: *mut Format, capacity: usize) -> usize;
    fn fp_gpu_submit(
        gpu: *mut c_void,
        image: *const Image,
        error: *mut c_char,
        capacity: usize,
    ) -> c_int;
    fn fp_gpu_poll(gpu: *mut c_void, error: *mut c_char, capacity: usize) -> c_int;
    fn fp_gpu_draw(
        gpu: *mut c_void,
        width: c_int,
        height: c_int,
        error: *mut c_char,
        capacity: usize,
    ) -> c_int;
    fn fp_gpu_destroy(gpu: *mut c_void);
}
fn error(buffer: &[c_char]) -> String {
    unsafe { CStr::from_ptr(buffer.as_ptr()) }
        .to_string_lossy()
        .into_owned()
}
struct Callbacks {
    ready: Box<dyn Fn(Renderer, &str)>,
    painted: Box<dyn Fn(u64, u32, u32, Instant)>,
    failed: Box<dyn Fn(&str)>,
}
struct InFlight {
    frame: Frame,
    began: Instant,
}
pub struct View {
    pub area: gtk::GLArea,
    native: RefCell<Option<NonNull<c_void>>>,
    context: RefCell<Option<gdk::GLContext>>,
    callbacks: RefCell<Option<Callbacks>>,
    initialised: Cell<bool>,
    supported: Cell<bool>,
    stopped: Cell<bool>,
    failed: Cell<bool>,
    completed: Cell<u64>,
    pending: RefCell<Option<Frame>>,
    flight: RefCell<Option<InFlight>>,
}
impl View {
    pub fn new() -> Rc<Self> {
        let area = gtk::GLArea::builder()
            .auto_render(false)
            .hexpand(true)
            .vexpand(true)
            .build();
        area.set_allowed_apis(gdk::GLAPI::GLES);
        area.set_required_version(3, 0);
        let this = Rc::new(Self {
            area,
            native: RefCell::new(None),
            context: RefCell::new(None),
            callbacks: RefCell::new(None),
            initialised: Cell::new(false),
            supported: Cell::new(false),
            stopped: Cell::new(false),
            failed: Cell::new(false),
            completed: Cell::new(0),
            pending: RefCell::new(None),
            flight: RefCell::new(None),
        });
        let weak = Rc::downgrade(&this);
        this.area.connect_realize(move |_| {
            if let Some(v) = weak.upgrade() {
                v.initialise();
            }
        });
        let weak = Rc::downgrade(&this);
        this.area.connect_render(move |_, _| {
            if let Some(v) = weak.upgrade() {
                if let Err(e) = v.render() {
                    v.fail(&e);
                }
            }
            glib::Propagation::Stop
        });
        let weak = Rc::downgrade(&this);
        this.area.connect_unrealize(move |_| {
            if let Some(v) = weak.upgrade() {
                if v.supported.get() && !v.stopped.get() {
                    v.fail("GPU 上下文已关闭，请重新连接");
                }
                v.retire();
            }
        });
        this
    }
    pub fn bind(
        &self,
        ready: impl Fn(Renderer, &str) + 'static,
        painted: impl Fn(u64, u32, u32, Instant) + 'static,
        failed: impl Fn(&str) + 'static,
    ) {
        *self.callbacks.borrow_mut() = Some(Callbacks {
            ready: Box::new(ready),
            painted: Box::new(painted),
            failed: Box::new(failed),
        });
    }
    fn initialise(&self) {
        if self.initialised.replace(true) {
            return;
        }
        self.area.make_current();
        // Keep the owning GDK context alive until its native handles retire;
        // an unrelated context must never reuse that EGL handle meanwhile.
        *self.context.borrow_mut() = self.area.context();
        let result = (|| {
            let composition = self
                .area
                .native()
                .and_then(|n| n.renderer())
                .ok_or("GTK 渲染器尚未就绪")?;
            if !matches!(
                composition.type_().name(),
                "GskGLRenderer" | "GskNglRenderer"
            ) {
                return Err("当前 GTK 渲染后端需要软件兼容模式".to_owned());
            }
            if let Some(e) = self.area.error() {
                return Err(e.to_string());
            }
            // GDK's default display contexts share with the GL compositor.
            // Match both the realised API and the public sharing contract;
            // merely seeing "GL" on both widgets does not establish this.
            let context = self.area.context().ok_or("缺少视频图形上下文")?;
            let shared = self
                .area
                .display()
                .create_gl_context()
                .map_err(|e| e.to_string())?;
            shared.realize().map_err(|e| e.to_string())?;
            let compatible = context.api() == shared.api() && context.is_shared(&shared);
            if let Some(directory) = crate::viewer::smoke_directory() {
                let report = serde_json::json!({
                    "composition": composition.type_().name(),
                    "area_api": format!("{:?}", context.api()),
                    "display_api": format!("{:?}", shared.api()),
                    "shared": compatible,
                });
                let _ = std::fs::write(directory.join("gl-sharing.json"), report.to_string());
            }
            if !compatible {
                return Err("视频与窗口图形上下文无法共享纹理".to_owned());
            }
            // Creating/realising the comparison context may change current GL.
            self.area.make_current();
            let mut message = [0; 1024];
            let pointer = NonNull::new(unsafe { fp_gpu_new(message.as_mut_ptr(), message.len()) })
                .ok_or_else(|| error(&message))?;
            *self.native.borrow_mut() = Some(pointer);
            let mut formats = [Format::default(); 128];
            let count =
                unsafe { fp_gpu_formats(pointer.as_ptr(), formats.as_mut_ptr(), formats.len()) };
            if count > formats.len() {
                return Err("无效的 GPU 格式列表".into());
            }
            if ![frame::R8, frame::GR88]
                .iter()
                .all(|f| formats[..count].iter().any(|value| value.format == *f))
            {
                return Err("当前图形驱动不支持所需的 DMA-BUF 分平面导入".into());
            }
            Ok(Renderer {
                software: false,
                formats: formats[..count]
                    .iter()
                    .map(|f| ImportFormat {
                        format: f.format,
                        modifier: f.modifier,
                    })
                    .collect(),
            })
        })();
        let (renderer, reason) = match result {
            Ok(renderer) => {
                self.supported.set(true);
                (renderer, "GPU 呈现已就绪".to_owned())
            }
            Err(reason) => {
                self.stopped.set(true);
                self.retire();
                (
                    Renderer {
                        software: true,
                        formats: vec![],
                    },
                    format!("软件兼容模式：{reason}"),
                )
            }
        };
        if let Some(callbacks) = self.callbacks.borrow().as_ref() {
            (callbacks.ready)(renderer, &reason);
        }
    }
    pub fn queue(&self, frame: Frame) -> Result<(), String> {
        if !self.supported.get() || self.stopped.get() {
            return Err("GPU 呈现已停止".into());
        }
        if let Some(previous) = self.pending.borrow_mut().replace(frame) {
            // This candidate has never been imported or submitted to the GPU.
            previous.discard().map_err(|e| e.to_string())?;
        }
        self.area.queue_render();
        Ok(())
    }
    fn render(&self) -> Result<(), String> {
        if !self.supported.get() || self.failed.get() {
            return Ok(());
        }
        self.poll_fence()?;
        let mut presented = None;
        if !self.stopped.get() && self.flight.borrow().is_none() {
            let pending = self.pending.borrow_mut().take();
            if let Some(frame) = pending {
                let Packet::DmaBuf(info) = &frame.packet else {
                    return Err("GPU 收到非 DMA-BUF 画面".into());
                };
                info.validate(frame.files.len(), info.generation)
                    .map_err(str::to_owned)?;
                let mut planes = [Plane::default(); 2];
                for (i, plane) in planes.iter_mut().enumerate() {
                    let layer = &info.layers[i];
                    let p = &layer.planes[0];
                    let object = &info.objects[p.object as usize];
                    *plane = Plane {
                        fd: frame.files[p.object as usize].as_raw_fd(),
                        format: layer.format,
                        width: info.width / if i == 0 { 1 } else { 2 },
                        height: info.height / if i == 0 { 1 } else { 2 },
                        pitch: p.pitch,
                        offset: p.offset,
                        modifier: object.modifier,
                    };
                }
                let image = Image {
                    width: info.width,
                    height: info.height,
                    planes,
                    matrix: i32::from(info.color.matrix == frame::Matrix::Bt709),
                    range: i32::from(info.color.range == frame::Range::Full),
                    chroma: i32::from(info.color.chroma == frame::Chroma::Center),
                };
                let pointer = self.native.borrow().ok_or("GPU 上下文不可用")?;
                let mut message = [0; 1024];
                let result = unsafe {
                    fp_gpu_submit(
                        pointer.as_ptr(),
                        &image,
                        message.as_mut_ptr(),
                        message.len(),
                    )
                };
                presented = Some((info.generation, info.width, info.height, frame.received));
                // Keep the owned FDs and lease even if submission failed after
                // issuing GPU work. Failure retires the worker, never ACKs it.
                *self.flight.borrow_mut() = Some(InFlight {
                    frame,
                    began: Instant::now(),
                });
                if result < 0 {
                    return Err(error(&message));
                }
            }
        }
        let pointer = self.native.borrow().ok_or("GPU 上下文不可用")?;
        let scale = self.area.scale_factor();
        let mut message = [0; 1024];
        if unsafe {
            fp_gpu_draw(
                pointer.as_ptr(),
                self.area.width().saturating_mul(scale),
                self.area.height().saturating_mul(scale),
                message.as_mut_ptr(),
                message.len(),
            )
        } < 0
        {
            return Err(error(&message));
        }
        if let Some((generation, width, height, received)) = presented {
            if let Some(callbacks) = self.callbacks.borrow().as_ref() {
                (callbacks.painted)(generation, width, height, received);
            }
        }
        Ok(())
    }
    fn poll_fence(&self) -> Result<(), String> {
        if self.flight.borrow().is_none() {
            return Ok(());
        }
        let pointer = self.native.borrow().ok_or("GPU 完成检查缺少上下文")?;
        let mut message = [0; 1024];
        match unsafe { fp_gpu_poll(pointer.as_ptr(), message.as_mut_ptr(), message.len()) } {
            1 => {
                let flight = self.flight.borrow_mut().take().unwrap();
                flight.frame.release().map_err(|e| e.to_string())?;
                self.completed.set(self.completed.get().saturating_add(1));
            }
            0 if self.flight.borrow().as_ref().unwrap().began.elapsed()
                < Duration::from_millis(450) => {}
            0 => return Err("GPU 呈现完成超时，会话已停止".into()),
            _ => return Err(error(&message)),
        }
        Ok(())
    }
    pub fn tick(&self) {
        if !self.supported.get() || self.failed.get() {
            return;
        }
        if self.flight.borrow().is_some() {
            self.area.make_current();
            if let Some(e) = self.area.error() {
                self.fail(&e.to_string());
                return;
            }
            if let Err(e) = self.poll_fence() {
                self.fail(&e);
                return;
            }
        }
        if !self.stopped.get() && self.flight.borrow().is_none() && self.pending.borrow().is_some()
        {
            self.area.queue_render();
        }
    }
    pub fn stop(&self) {
        self.stopped.set(true);
        if let Some(frame) = self.pending.borrow_mut().take() {
            let _ = frame.release();
        }
    }
    pub fn idle(&self) -> bool {
        self.failed.get() || self.flight.borrow().is_none()
    }
    pub fn loans(&self) -> u32 {
        u32::from(self.pending.borrow().is_some()) + u32::from(self.flight.borrow().is_some())
    }
    pub fn completed(&self) -> u64 {
        self.completed.get()
    }
    fn fail(&self, reason: &str) {
        self.stop();
        if !self.failed.replace(true) {
            if let Some(callbacks) = self.callbacks.borrow().as_ref() {
                (callbacks.failed)(reason);
            }
        }
    }
    fn retire(&self) {
        self.stop();
        if let Some(pointer) = self.native.borrow_mut().take() {
            if self.area.is_realized() {
                self.area.make_current();
            }
            unsafe {
                fp_gpu_destroy(pointer.as_ptr());
            }
        }
        // Context teardown is not an acknowledgement. The worker was stopped.
        self.flight.borrow_mut().take();
        self.context.borrow_mut().take();
    }
}
impl Drop for View {
    fn drop(&mut self) {
        self.retire();
    }
}
