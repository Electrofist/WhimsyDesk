//! Text for the labels and the empty-drawer hint, drawn with GDI into a grey-scale coverage mask
//! (white text on black, anti-aliased). `sprite::Sprite::from_mask` colours it.

use super::util::wide;
use windows::core::PCWSTR;
use windows::Win32::Foundation::{COLORREF, RECT, SIZE};
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, CreateFontW, DeleteDC, DeleteObject, DrawTextW,
    GetTextExtentPoint32W, SelectObject, SetBkMode, SetTextColor, ANTIALIASED_QUALITY, BITMAPINFO,
    BITMAPINFOHEADER, BI_RGB, CLIP_DEFAULT_PRECIS, DEFAULT_CHARSET, DIB_RGB_COLORS, DT_CENTER,
    DT_NOCLIP, DT_NOPREFIX, DT_SINGLELINE, DT_VCENTER, OUT_DEFAULT_PRECIS, TRANSPARENT,
};

const FONT: &str = "Segoe UI";
const SEMIBOLD: i32 = 600;

/// A coverage mask, `w * h` bytes.
pub struct Mask {
    pub w: usize,
    pub h: usize,
    pub data: Vec<u8>,
}

fn extent(dc: windows::Win32::Graphics::Gdi::HDC, text: &[u16]) -> i32 {
    let mut size = SIZE::default();
    unsafe {
        let _ = GetTextExtentPoint32W(dc, text, &mut size);
    }
    size.cx
}

/// `text` shortened in the middle ("long na…me.txt") until it fits `max_w` pixels.
fn fit_middle(dc: windows::Win32::Graphics::Gdi::HDC, text: &str, max_w: i32) -> Vec<u16> {
    let all: Vec<u16> = text.encode_utf16().collect();
    if extent(dc, &all) <= max_w {
        return all;
    }
    let chars: Vec<char> = text.chars().collect();
    for keep in (1..chars.len()).rev() {
        let head: String = chars[..keep.div_ceil(2)].iter().collect();
        let tail: String = chars[chars.len() - keep / 2..].iter().collect();
        let candidate: Vec<u16> = format!("{head}…{tail}").encode_utf16().collect();
        if extent(dc, &candidate) <= max_w {
            return candidate;
        }
    }
    "…".encode_utf16().collect()
}

/// Draws `text` centred in a `w` x `h` box, in Segoe UI semibold of `font_px` pixels, shortened in
/// the middle if it is too wide. With `w == 0` the box is as wide as the text.
pub fn render(text: &str, w: usize, h: usize, font_px: f64, truncate: bool) -> Option<Mask> {
    unsafe {
        let dc = CreateCompatibleDC(None);
        if dc.is_invalid() {
            return None;
        }
        let face = wide(FONT);
        let font = CreateFontW(
            -(font_px.round() as i32),
            0,
            0,
            0,
            SEMIBOLD,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            ANTIALIASED_QUALITY, // grey-scale: we need coverage, not coloured fringes
            0,
            PCWSTR(face.as_ptr()),
        );
        let old_font = SelectObject(dc, font.into());
        let mut line: Vec<u16> = if truncate && w > 0 {
            fit_middle(dc, text, w as i32)
        } else {
            text.encode_utf16().collect()
        };
        let w = if w == 0 {
            extent(dc, &line).max(1) as usize + 2
        } else {
            w
        };
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w as i32,
                biHeight: -(h as i32),
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        let result = match CreateDIBSection(Some(dc), &info, DIB_RGB_COLORS, &mut bits, None, 0) {
            Ok(bitmap) => {
                let old_bitmap = SelectObject(dc, bitmap.into());
                SetBkMode(dc, TRANSPARENT);
                SetTextColor(dc, COLORREF(0x00FF_FFFF));
                let mut rect = RECT {
                    left: 0,
                    top: 0,
                    right: w as i32,
                    bottom: h as i32,
                };
                DrawTextW(
                    dc,
                    &mut line,
                    &mut rect,
                    DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX | DT_NOCLIP,
                );
                let px = std::slice::from_raw_parts(bits as *const u8, w * h * 4);
                let data = px
                    .chunks_exact(4)
                    .map(|p| p[0].max(p[1]).max(p[2]))
                    .collect();
                SelectObject(dc, old_bitmap);
                let _ = DeleteObject(bitmap.into());
                Some(Mask { w, h, data })
            }
            Err(_) => None,
        };
        SelectObject(dc, old_font);
        let _ = DeleteObject(font.into());
        let _ = DeleteDC(dc);
        result
    }
}
