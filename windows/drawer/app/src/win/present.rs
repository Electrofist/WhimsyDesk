//! Pushes frames to the layered window with `UpdateLayeredWindow` (per-pixel alpha, so fully
//! transparent pixels let clicks through to the desktop).
//!
//! The bitmap is allocated once at the full open-drawer height. A frame is drawn straight into
//! its first `h` rows (the bitmap is top-down, so those are contiguous) and shown with the
//! window's current, shorter size.

use windows::Win32::Foundation::{COLORREF, HWND, POINT, SIZE};
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, SelectObject, AC_SRC_ALPHA,
    AC_SRC_OVER, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, BLENDFUNCTION, DIB_RGB_COLORS, HBITMAP, HDC,
    HGDIOBJ,
};
use windows::Win32::UI::WindowsAndMessaging::{UpdateLayeredWindow, ULW_ALPHA};

/// A premultiplied 32-bit top-down DIB section selected into a memory DC.
pub struct Surface {
    dc: HDC,
    bitmap: HBITMAP,
    old: HGDIOBJ,
    bits: *mut u8,
    size: (i32, i32),
}

impl Surface {
    pub fn new() -> Surface {
        Surface {
            dc: HDC::default(),
            bitmap: HBITMAP::default(),
            old: HGDIOBJ::default(),
            bits: std::ptr::null_mut(),
            size: (0, 0),
        }
    }

    fn release(&mut self) {
        unsafe {
            if !self.dc.is_invalid() {
                SelectObject(self.dc, self.old);
                let _ = DeleteObject(self.bitmap.into());
                let _ = DeleteDC(self.dc);
            }
        }
        // Reset field by field: `*self = Surface::new()` would run Drop on the old value, which
        // calls release again.
        self.dc = HDC::default();
        self.bitmap = HBITMAP::default();
        self.old = HGDIOBJ::default();
        self.bits = std::ptr::null_mut();
        self.size = (0, 0);
    }

    fn ensure(&mut self, w: i32, h: i32) -> bool {
        if self.size == (w, h) && !self.bits.is_null() {
            return true;
        }
        self.release();
        unsafe {
            let dc = CreateCompatibleDC(None);
            if dc.is_invalid() {
                return false;
            }
            let info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: w,
                    biHeight: -h, // top-down
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let mut bits = std::ptr::null_mut();
            let Ok(bitmap) = CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0)
            else {
                let _ = DeleteDC(dc);
                return false;
            };
            let old = SelectObject(dc, bitmap.into());
            self.dc = dc;
            self.bitmap = bitmap;
            self.old = old;
            self.bits = bits as *mut u8;
            self.size = (w, h);
        }
        true
    }

    /// The pixels of a `w` x `h` frame (`w * h * 4` bytes, BGRA premultiplied), backed by a
    /// bitmap of `w` x `max_h`. None if the bitmap could not be made.
    pub fn pixels(&mut self, w: i32, h: i32, max_h: i32) -> Option<&mut [u8]> {
        if w <= 0 || h <= 0 || h > max_h || !self.ensure(w, max_h) {
            return None;
        }
        Some(unsafe { std::slice::from_raw_parts_mut(self.bits, (w * h * 4) as usize) })
    }

    /// Shows the first `size.1` rows of the bitmap in the window at `origin`.
    pub fn show(&mut self, hwnd: HWND, origin: (i32, i32), size: (i32, i32)) -> bool {
        if self.bits.is_null() {
            return false;
        }
        unsafe {
            let pos = POINT {
                x: origin.0,
                y: origin.1,
            };
            let sz = SIZE {
                cx: size.0,
                cy: size.1,
            };
            let src = POINT { x: 0, y: 0 };
            let blend = BLENDFUNCTION {
                BlendOp: AC_SRC_OVER as u8,
                BlendFlags: 0,
                SourceConstantAlpha: 255,
                AlphaFormat: AC_SRC_ALPHA as u8,
            };
            UpdateLayeredWindow(
                hwnd,
                None,
                Some(&pos),
                Some(&sz),
                Some(self.dc),
                Some(&src),
                COLORREF(0),
                Some(&blend),
                ULW_ALPHA,
            )
            .is_ok()
        }
    }
}

impl Drop for Surface {
    fn drop(&mut self) {
        self.release();
    }
}
