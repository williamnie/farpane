//! Cursor textures belong to this Viewer and never apply to local toolbars.
use adw::prelude::*;
use gtk::{gdk, glib};
use std::{cell::RefCell, collections::VecDeque};

const MAX_SIDE: u32 = 96;
const CACHE: usize = 32;
pub struct Cursors {
    target: glib::WeakRef<gtk::Widget>,
    shapes: RefCell<VecDeque<(u64, gdk::Cursor)>>,
}
impl Cursors {
    pub fn new(target: &impl IsA<gtk::Widget>) -> Self {
        Self {
            target: target.as_ref().downgrade(),
            shapes: RefCell::new(VecDeque::new()),
        }
    }
    pub fn update(
        &self,
        id: u64,
        width: u32,
        height: u32,
        hot_x: i32,
        hot_y: i32,
        encoded: &str,
        premultiplied: bool,
    ) {
        if width == 0 && height == 0 && encoded.is_empty() {
            self.select(id);
            return;
        }
        if width == 0
            || height == 0
            || width > MAX_SIDE
            || height > MAX_SIDE
            || hot_x < 0
            || hot_y < 0
            || hot_x >= width as i32
            || hot_y >= height as i32
        {
            self.fallback();
            return;
        }
        let length = width as usize * height as usize * 4;
        if encoded.len() != length.div_ceil(3) * 4
            || !encoded
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(&b))
        {
            self.fallback();
            return;
        }
        let pixels = glib::base64_decode(encoded);
        if pixels.len() != length {
            self.fallback();
            return;
        }
        let bytes = glib::Bytes::from_owned(pixels);
        let texture = gdk::MemoryTexture::new(
            width as i32,
            height as i32,
            if premultiplied {
                gdk::MemoryFormat::R8g8b8a8Premultiplied
            } else {
                gdk::MemoryFormat::R8g8b8a8
            },
            &bytes,
            width as usize * 4,
        );
        let fallback = gdk::Cursor::from_name("default", None);
        let cursor = gdk::Cursor::from_texture(&texture, hot_x, hot_y, fallback.as_ref());
        {
            let mut shapes = self.shapes.borrow_mut();
            shapes.retain(|(key, _)| *key != id);
            if shapes.len() == CACHE {
                shapes.pop_front();
            }
            shapes.push_back((id, cursor));
        }
        self.select(id);
    }
    fn select(&self, id: u64) {
        let cursor = {
            let mut shapes = self.shapes.borrow_mut();
            let found = shapes.iter().position(|(key, _)| *key == id);
            found.map(|index| {
                let value = shapes.remove(index).unwrap();
                let cursor = value.1.clone();
                shapes.push_back(value);
                cursor
            })
        };
        if let Some(target) = self.target.upgrade() {
            target.set_cursor(cursor.as_ref());
        }
    }
    fn fallback(&self) {
        if let Some(target) = self.target.upgrade() {
            target.set_cursor(None);
        }
    }
    pub fn clear(&self) {
        self.fallback();
        self.shapes.borrow_mut().clear();
    }
}
