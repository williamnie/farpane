use adw::prelude::*;
use farpane_protocol::{Display, Input, PointerAction};
use gtk::{
    gdk,
    glib::{self, translate::IntoGlib},
};
use std::{
    cell::{Cell, RefCell},
    collections::BTreeSet,
    rc::Rc,
};

pub struct Controls {
    target: glib::WeakRef<gtk::Widget>,
    display: RefCell<Option<Display>>,
    image: Cell<(u32, u32)>,
    ready: Cell<bool>,
    keys: RefCell<BTreeSet<u32>>,
    buttons: Cell<u8>,
    im: gtk::IMMulticontext,
    im_attached: Cell<bool>,
    preedit: gtk::Label,
    exclusive: gtk::ToggleButton,
    changing: Cell<bool>,
    toplevel: RefCell<Option<(glib::WeakRef<gdk::Toplevel>, glib::SignalHandlerId)>>,
    active: RefCell<Option<(glib::WeakRef<gtk::Window>, glib::SignalHandlerId)>>,
    send: Box<dyn Fn(Input)>,
}
fn modifiers(state: gdk::ModifierType) -> u32 {
    u32::from(state.contains(gdk::ModifierType::SHIFT_MASK))
        | u32::from(state.contains(gdk::ModifierType::CONTROL_MASK)) * 2
        | u32::from(state.contains(gdk::ModifierType::ALT_MASK)) * 4
        | u32::from(state.intersects(gdk::ModifierType::SUPER_MASK | gdk::ModifierType::META_MASK))
            * 8
        | u32::from(state.contains(gdk::ModifierType::LOCK_MASK)) * 16
        | u32::from(state.bits() & 0x10 != 0) * 32
}
fn button(value: u32) -> u8 {
    match value {
        1 => 1,
        2 => 4,
        3 => 2,
        8 => 8,
        9 => 16,
        _ => 0,
    }
}
pub(crate) fn point(
    size: (f64, f64),
    image: (u32, u32),
    display: &Display,
    x: f64,
    y: f64,
    clamp: bool,
) -> Option<(i32, i32)> {
    if image.0 == 0
        || image.1 == 0
        || size.0 <= 0.
        || size.1 <= 0.
        || !x.is_finite()
        || !y.is_finite()
    {
        return None;
    }
    let scale = (size.0 / image.0 as f64).min(size.1 / image.1 as f64);
    let (w, h) = (image.0 as f64 * scale, image.1 as f64 * scale);
    let (u, v) = ((x - (size.0 - w) / 2.) / w, (y - (size.1 - h) / 2.) / h);
    if !clamp && (!(0. ..1.).contains(&u) || !(0. ..1.).contains(&v)) {
        return None;
    }
    let px = (u.clamp(0., 1.) * display.width as f64)
        .floor()
        .min(display.width.saturating_sub(1) as f64) as i64
        + display.x as i64;
    let py = (v.clamp(0., 1.) * display.height as f64)
        .floor()
        .min(display.height.saturating_sub(1) as f64) as i64
        + display.y as i64;
    Some((i32::try_from(px).ok()?, i32::try_from(py).ok()?))
}
impl Controls {
    pub fn new(
        target: &impl IsA<gtk::Widget>,
        overlay: &gtk::Overlay,
        exclusive: &gtk::ToggleButton,
        send: impl Fn(Input) + 'static,
    ) -> Rc<Self> {
        let widget = target.as_ref();
        widget.set_focusable(true);
        widget.set_focus_on_click(true);
        let preedit = gtk::Label::new(None);
        preedit.add_css_class("viewer-hud");
        preedit.set_halign(gtk::Align::Center);
        preedit.set_valign(gtk::Align::End);
        preedit.set_margin_bottom(24);
        preedit.set_visible(false);
        overlay.add_overlay(&preedit);
        let im = gtk::IMMulticontext::new();
        im.set_client_widget(Some(widget));
        im.set_use_preedit(true);
        let this = Rc::new(Self {
            target: widget.downgrade(),
            display: RefCell::new(None),
            image: Cell::new((0, 0)),
            ready: Cell::new(false),
            keys: RefCell::new(BTreeSet::new()),
            buttons: Cell::new(0),
            im,
            im_attached: Cell::new(true),
            preedit,
            exclusive: exclusive.clone(),
            changing: Cell::new(false),
            toplevel: RefCell::new(None),
            active: RefCell::new(None),
            send: Box::new(send),
        });
        exclusive.set_sensitive(false);
        exclusive.set_tooltip_text(Some("仅在桌面实际授权后独占系统快捷键；离开画面自动释放"));
        let weak = Rc::downgrade(&this);
        exclusive.connect_toggled(move |button| {
            if let Some(c) = weak.upgrade() {
                if c.changing.get() {
                    return;
                }
                if let Some((top, _)) = c.toplevel.borrow().as_ref() {
                    if let Some(top) = top.upgrade() {
                        if button.is_active() && c.ready.get() {
                            if let Some(target) = c.target.upgrade() {
                                target.grab_focus();
                            }
                            top.inhibit_system_shortcuts(None::<&gdk::Event>);
                            button.set_label("请求独占…");
                            let weak = Rc::downgrade(&c);
                            glib::timeout_add_local_once(
                                std::time::Duration::from_secs(1),
                                move || {
                                    if let Some(c) = weak.upgrade() {
                                        let granted = c
                                            .toplevel
                                            .borrow()
                                            .as_ref()
                                            .and_then(|(t, _)| t.upgrade())
                                            .is_some_and(|t| t.is_shortcuts_inhibited());
                                        if !granted {
                                            c.changing.set(true);
                                            c.exclusive.set_active(false);
                                            c.exclusive.set_label("独占未获授权");
                                            c.changing.set(false);
                                        }
                                    }
                                },
                            );
                        } else {
                            top.restore_system_shortcuts();
                        }
                    }
                }
            }
        });
        let weak = Rc::downgrade(&this);
        widget.connect_realize(move |widget| {
            if let Some(c) = weak.upgrade() {
                if !c.im_attached.replace(true) {
                    c.im.set_client_widget(Some(widget));
                }
                if let Some(window) = widget.root().and_downcast::<gtk::Window>() {
                    let weak = Rc::downgrade(&c);
                    let handler = window.connect_is_active_notify(move |window| {
                        if let Some(c) = weak.upgrade() {
                            if !window.is_active() {
                                c.release();
                                c.im.focus_out();
                            } else if c.ready.get()
                                && c.target.upgrade().is_some_and(|w| w.has_focus())
                            {
                                c.im.focus_in();
                            }
                        }
                    });
                    *c.active.borrow_mut() = Some((window.downgrade(), handler));
                }
                let Some(top) = widget
                    .native()
                    .and_then(|n| n.surface())
                    .and_then(|s| s.dynamic_cast::<gdk::Toplevel>().ok())
                else {
                    return;
                };
                let weak = Rc::downgrade(&c);
                let handler = top.connect_shortcuts_inhibited_notify(move |top| {
                    if let Some(c) = weak.upgrade() {
                        c.changing.set(true);
                        c.exclusive.set_active(top.is_shortcuts_inhibited());
                        c.exclusive.set_label(if top.is_shortcuts_inhibited() {
                            "键盘已独占"
                        } else {
                            "独占键盘"
                        });
                        c.changing.set(false);
                    }
                });
                *c.toplevel.borrow_mut() = Some((top.downgrade(), handler));
            }
        });
        let weak = Rc::downgrade(&this);
        widget.connect_unrealize(move |_| {
            if let Some(c) = weak.upgrade() {
                c.detach();
            }
        });
        let key = gtk::EventControllerKey::new();
        // Filter explicitly: EventControllerKey's built-in IM filtering can
        // consume a release after we forwarded the corresponding press.
        let weak = Rc::downgrade(&this);
        key.connect_key_pressed(move |controller, keyval, code, state| {
            let Some(c) = weak.upgrade() else {
                return glib::Propagation::Proceed;
            };
            if !c.ready.get() {
                return glib::Propagation::Proceed;
            }
            if controller
                .current_event()
                .is_some_and(|event| c.im.filter_keypress(event))
            {
                return glib::Propagation::Stop;
            }
            c.keys.borrow_mut().insert(code);
            (c.send)(Input::Key {
                keyval: keyval.into_glib(),
                hardware_code: code,
                pressed: true,
                modifiers: modifiers(state),
            });
            glib::Propagation::Stop
        });
        let weak = Rc::downgrade(&this);
        key.connect_key_released(move |controller, keyval, code, state| {
            if let Some(c) = weak.upgrade() {
                if c.keys.borrow_mut().remove(&code) {
                    (c.send)(Input::Key {
                        keyval: keyval.into_glib(),
                        hardware_code: code,
                        pressed: false,
                        modifiers: modifiers(state),
                    });
                }
                if c.ready.get() {
                    if let Some(event) = controller.current_event() {
                        c.im.filter_keypress(event);
                    }
                }
            }
        });
        widget.add_controller(key);
        let weak = Rc::downgrade(&this);
        this.im.connect_commit(move |_, text| {
            if let Some(c) = weak.upgrade() {
                if c.ready.get() && c.target.upgrade().is_some_and(|w| w.has_focus()) {
                    (c.send)(Input::Text { text: text.into() });
                }
            }
        });
        let weak = Rc::downgrade(&this);
        this.im.connect_preedit_changed(move |im| {
            if let Some(c) = weak.upgrade() {
                let (text, attrs, _) = im.preedit_string();
                if !text.is_empty() {
                    // Composition owns these keys locally. Release any prefix
                    // modifiers already forwarded without resetting the IME.
                    c.release_remote();
                }
                c.preedit.set_text(&text);
                c.preedit.set_attributes(Some(&attrs));
                c.preedit.set_visible(c.ready.get() && !text.is_empty());
            }
        });
        let focus = gtk::EventControllerFocus::new();
        let weak = Rc::downgrade(&this);
        focus.connect_enter(move |_| {
            if let Some(c) = weak.upgrade() {
                if c.ready.get() {
                    c.im.focus_in();
                }
            }
        });
        let weak = Rc::downgrade(&this);
        focus.connect_leave(move |_| {
            if let Some(c) = weak.upgrade() {
                c.release();
                c.im.focus_out();
            }
        });
        widget.add_controller(focus);
        let gesture = gtk::GestureClick::new();
        gesture.set_button(0);
        let weak = Rc::downgrade(&this);
        gesture.connect_pressed(move |g, _, x, y| {
            if let Some(c) = weak.upgrade() {
                let button = button(g.current_button());
                if !c.ready.get() || button == 0 {
                    return;
                }
                if let Some((x, y)) = c.coordinates(x, y, false) {
                    if let Some(target) = c.target.upgrade() {
                        target.grab_focus();
                    }
                    c.buttons.set(c.buttons.get() | button);
                    (c.send)(Input::Pointer {
                        x,
                        y,
                        buttons: button,
                        action: PointerAction::Press,
                        modifiers: modifiers(g.current_event_state()),
                    });
                    g.set_state(gtk::EventSequenceState::Claimed);
                }
            }
        });
        let weak = Rc::downgrade(&this);
        gesture.connect_released(move |g, _, x, y| {
            if let Some(c) = weak.upgrade() {
                let button = button(g.current_button());
                if c.buttons.get() & button == 0 {
                    return;
                }
                c.buttons.set(c.buttons.get() & !button);
                if let Some((x, y)) = c.coordinates(x, y, true) {
                    (c.send)(Input::Pointer {
                        x,
                        y,
                        buttons: button,
                        action: PointerAction::Release,
                        modifiers: modifiers(g.current_event_state()),
                    });
                }
            }
        });
        widget.add_controller(gesture);
        let motion = gtk::EventControllerMotion::new();
        let weak = Rc::downgrade(&this);
        motion.connect_motion(move |m, x, y| {
            if let Some(c) = weak.upgrade() {
                if !c.ready.get() {
                    return;
                }
                if let Some((x, y)) = c.coordinates(x, y, c.buttons.get() != 0) {
                    c.im.set_cursor_location(&gdk::Rectangle::new(8, 8, 1, 24));
                    (c.send)(Input::Pointer {
                        x,
                        y,
                        buttons: 0,
                        action: PointerAction::Move,
                        modifiers: modifiers(m.current_event_state()),
                    });
                }
            }
        });
        let weak = Rc::downgrade(&this);
        motion.connect_leave(move |_| {
            if let Some(c) = weak.upgrade() {
                c.release();
            }
        });
        widget.add_controller(motion);
        let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::BOTH_AXES);
        let weak = Rc::downgrade(&this);
        scroll.connect_scroll(move |s, x, y| {
            let Some(c) = weak.upgrade() else {
                return glib::Propagation::Proceed;
            };
            if !c.ready.get() {
                return glib::Propagation::Proceed;
            }
            let precise = s
                .current_event()
                .and_then(|e| e.downcast::<gdk::ScrollEvent>().ok())
                .is_some_and(|e| e.unit() == gdk::ScrollUnit::Surface);
            (c.send)(Input::Scroll {
                x,
                y,
                precise,
                modifiers: modifiers(s.current_event_state()),
            });
            glib::Propagation::Stop
        });
        widget.add_controller(scroll);
        this
    }
    fn coordinates(&self, x: f64, y: f64, clamp: bool) -> Option<(i32, i32)> {
        let target = self.target.upgrade()?;
        let display = self.display.borrow();
        point(
            (target.width() as f64, target.height() as f64),
            self.image.get(),
            display.as_ref()?,
            x,
            y,
            clamp,
        )
    }
    pub fn set_display(&self, display: Option<Display>) {
        self.release();
        *self.display.borrow_mut() = display;
    }
    pub fn set_image(&self, width: u32, height: u32) {
        self.image.set((width, height));
    }
    pub fn set_ready(&self, ready: bool) {
        if !ready && self.ready.get() {
            self.release();
            self.im.focus_out();
        }
        self.ready.set(ready);
        self.exclusive.set_sensitive(ready);
    }
    fn release_remote(&self) {
        if self.ready.get() {
            (self.send)(Input::ReleaseAll);
        }
        self.keys.borrow_mut().clear();
        self.buttons.set(0);
    }
    pub fn release(&self) {
        self.release_remote();
        self.im.reset();
        self.preedit.set_visible(false);
        if let Some((top, _)) = self.toplevel.borrow().as_ref() {
            if let Some(top) = top.upgrade() {
                top.restore_system_shortcuts();
            }
        }
        self.changing.set(true);
        self.exclusive.set_active(false);
        self.exclusive.set_label("独占键盘");
        self.changing.set(false);
    }
    pub fn detach(&self) {
        self.set_ready(false);
        if self.im_attached.replace(false) {
            // The IM module must disconnect from settings while its client
            // widget is still alive, before GTK tears down the window tree.
            self.im.set_client_widget(None::<&gtk::Widget>);
        }
    }
}
impl Drop for Controls {
    fn drop(&mut self) {
        self.detach();
        if let Some((window, id)) = self.active.get_mut().take() {
            if let Some(window) = window.upgrade() {
                if unsafe {
                    glib::gobject_ffi::g_signal_handler_is_connected(
                        window.as_ptr().cast(),
                        id.as_raw(),
                    )
                } != 0
                {
                    window.disconnect(id);
                }
            }
        }
        if let Some((top, id)) = self.toplevel.get_mut().take() {
            if let Some(top) = top.upgrade() {
                if unsafe {
                    glib::gobject_ffi::g_signal_handler_is_connected(
                        top.as_ptr().cast(),
                        id.as_raw(),
                    )
                } != 0
                {
                    top.disconnect(id);
                }
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn letterbox_hidpi_and_negative_monitor_origin_map_to_remote_coordinates() {
        let d = Display {
            index: 1,
            x: -2560,
            y: 100,
            width: 2560,
            height: 1440,
            name: String::new(),
        };
        assert_eq!(
            point((1000., 1000.), (1280, 720), &d, 500., 500., false),
            Some((-1280, 820))
        );
        assert_eq!(
            point((1000., 1000.), (1280, 720), &d, 500., 100., false),
            None
        );
        assert_eq!(
            point((1000., 1000.), (1280, 720), &d, 1200., 2000., true),
            Some((-1, 1539))
        );
    }
}
