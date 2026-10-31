//! Mouse cursors: the drawn hands from `cursors.rs`, the system arrow and a resize arrow.
//! The current cursor lives in a thread-local so WM_SETCURSOR can answer without the app state.

use crate::cursors::{hand, CursorImage, Hand};
use crate::model::Cursor;
use std::cell::Cell;
use windows::core::BOOL;
use windows::Win32::Graphics::Gdi::{
    CreateBitmap, CreateDIBSection, DeleteObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateIconIndirect, DestroyCursor, LoadCursorW, SetCursor, HCURSOR, ICONINFO, IDC_ARROW, IDC_SIZENESW,
};

thread_local! {
    static CURRENT: Cell<HCURSOR> = Cell::new(HCURSOR::default());
}

pub struct Cursors {
    arrow: HCURSOR,
    resize: HCURSOR,
    open: Option<HCURSOR>,
    closed: Option<HCURSOR>,
    current: Cursor,
}

impl Cursors {
    pub fn new(dpi_scale: f64) -> Cursors {
        unsafe {
            let arrow = LoadCursorW(None, IDC_ARROW).unwrap_or_default();
            let resize = LoadCursorW(None, IDC_SIZENESW).unwrap_or(arrow);
            let mut c = Cursors { arrow, resize, open: None, closed: None, current: Cursor::Arrow };
            c.set_dpi(dpi_scale);
            CURRENT.with(|k| k.set(arrow));
            c
        }
    }

    /// The hands are drawn in whole pixels per cell, so remake them when the DPI changes.
    pub fn set_dpi(&mut self, dpi_scale: f64) {
        self.free_hands();
        self.open = make(&hand(Hand::Open, dpi_scale));
        self.closed = make(&hand(Hand::Closed, dpi_scale));
        let c = self.current;
        self.set(c);
    }

    fn handle(&self, c: Cursor) -> HCURSOR {
        match c {
            Cursor::Arrow => self.arrow,
            Cursor::Resize => self.resize,
            Cursor::OpenHand => self.open.unwrap_or(self.arrow),
            Cursor::ClosedHand => self.closed.unwrap_or(self.arrow),
        }
    }

    pub fn set(&mut self, c: Cursor) {
        self.current = c;
        let h = self.handle(c);
        CURRENT.with(|k| k.set(h));
        unsafe {
            SetCursor(Some(h));
        }
    }

    fn free_hands(&mut self) {
        unsafe {
            for h in [self.open.take(), self.closed.take()].into_iter().flatten() {
                if CURRENT.with(|k| k.get()) == h {
                    CURRENT.with(|k| k.set(self.arrow));
                    SetCursor(Some(self.arrow));
                }
                let _ = DestroyCursor(h);
            }
        }
    }
}

impl Drop for Cursors {
    fn drop(&mut self) {
        self.free_hands();
    }
}

/// For WM_SETCURSOR.
pub fn apply_current() {
    let h = CURRENT.with(|k| k.get());
    if !h.is_invalid() {
        unsafe {
            SetCursor(Some(h));
        }
    }
}

/// A 32-bit cursor with alpha from straight BGRA.
fn make(img: &CursorImage) -> Option<HCURSOR> {
    let n = img.size as i32;
    unsafe {
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: n,
                biHeight: -n,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        let color = CreateDIBSection(None, &info, DIB_RGB_COLORS, &mut bits, None, 0).ok()?;
        std::ptr::copy_nonoverlapping(img.bgra.as_ptr(), bits as *mut u8, img.bgra.len());
        // The mask is ignored for alpha cursors but must exist. Rows are padded to 16 bits.
        let mask_bytes = vec![0u8; (((n + 15) / 16) * 2 * n) as usize];
        let mask = CreateBitmap(n, n, 1, 1, Some(mask_bytes.as_ptr() as *const _));
        let icon = ICONINFO {
            fIcon: BOOL(0),
            xHotspot: img.hotspot.0,
            yHotspot: img.hotspot.1,
            hbmMask: mask,
            hbmColor: color,
        };
        let cursor = CreateIconIndirect(&icon).ok();
        let _ = DeleteObject(color.into());
        let _ = DeleteObject(mask.into());
        cursor.map(|h| HCURSOR(h.0))
    }
}
