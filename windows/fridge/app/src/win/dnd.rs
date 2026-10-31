//! OLE drag and drop: files and text dropped onto the fridge, and items dragged out of it.
//!
//! Drops onto the fridge only record what to do; the files are moved after the drop returns
//! (see `super::on_drop`), because the source is still inside its drag loop and Desktop icon
//! positions cannot be read from Explorer until it is out of it. The drop answers "no effect" for
//! files it will move itself, so the source never deletes anything on our behalf.

use super::util::{path_from_wide, wide_path};
use crate::model::{Allowed, DragInfo, DropEffect};
use fridge_art::Image;
use std::cell::RefCell;
use std::path::Path;
use windows::core::{implement, Ref, BOOL, HRESULT};
use windows::Win32::Foundation::{
    DRAGDROP_S_CANCEL, DRAGDROP_S_DROP, DRAGDROP_S_USEDEFAULTCURSORS, HGLOBAL, HWND, POINT, POINTL, S_OK, SIZE, COLORREF,
};
use windows::Win32::Graphics::Gdi::{CreateDIBSection, DeleteObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS};
use windows::Win32::System::Com::{CoCreateInstance, IDataObject, CLSCTX_INPROC_SERVER, DVASPECT_CONTENT, FORMATETC, TYMED_HGLOBAL};
use windows::Win32::System::Memory::{GlobalLock, GlobalSize, GlobalUnlock};
use windows::Win32::System::Ole::{
    DoDragDrop, IDropSource, IDropSource_Impl, IDropTarget, IDropTarget_Impl, ReleaseStgMedium, CF_HDROP, CF_UNICODETEXT,
    DROPEFFECT, DROPEFFECT_COPY, DROPEFFECT_LINK, DROPEFFECT_MOVE, DROPEFFECT_NONE,
};
use windows::Win32::System::SystemServices::{MK_LBUTTON, MODIFIERKEYS_FLAGS};
use windows::Win32::UI::Shell::Common::ITEMIDLIST;
use windows::Win32::UI::Shell::{
    DragQueryFileW, ILClone, ILFindLastID, ILFree, ILRemoveLastID, IDragSourceHelper, IDropTargetHelper,
    SHCreateDataObject, SHParseDisplayName, CLSID_DragDropHelper, HDROP, SHDRAGIMAGE,
};

pub fn allowed(e: DROPEFFECT) -> Allowed {
    Allowed { copy: e.0 & DROPEFFECT_COPY.0 != 0, move_: e.0 & DROPEFFECT_MOVE.0 != 0, link: e.0 & DROPEFFECT_LINK.0 != 0 }
}

pub fn to_dropeffect(e: DropEffect) -> DROPEFFECT {
    match e {
        DropEffect::None => DROPEFFECT_NONE,
        DropEffect::Copy => DROPEFFECT_COPY,
        DropEffect::Move => DROPEFFECT_MOVE,
        DropEffect::Link => DROPEFFECT_LINK,
    }
}

fn format(cf: u16) -> FORMATETC {
    FORMATETC { cfFormat: cf, ptd: std::ptr::null_mut(), dwAspect: DVASPECT_CONTENT.0, lindex: -1, tymed: TYMED_HGLOBAL.0 as u32 }
}

/// File paths (CF_HDROP) or, failing that, plain text (CF_UNICODETEXT).
pub fn read_drag_info(data: &IDataObject) -> DragInfo {
    let mut info = DragInfo::default();
    unsafe {
        if let Ok(mut medium) = data.GetData(&format(CF_HDROP.0)) {
            let hdrop = HDROP(medium.u.hGlobal.0);
            let count = DragQueryFileW(hdrop, u32::MAX, None);
            for i in 0..count {
                let len = DragQueryFileW(hdrop, i, None) as usize;
                if len == 0 {
                    continue;
                }
                let mut buf = vec![0u16; len + 1];
                DragQueryFileW(hdrop, i, Some(&mut buf));
                info.files.push(path_from_wide(&buf));
            }
            ReleaseStgMedium(&mut medium);
        }
        if info.files.is_empty() {
            if let Ok(mut medium) = data.GetData(&format(CF_UNICODETEXT.0)) {
                info.text = global_text(medium.u.hGlobal);
                ReleaseStgMedium(&mut medium);
            }
        }
    }
    info
}

unsafe fn global_text(h: HGLOBAL) -> Option<String> {
    let p = GlobalLock(h) as *const u16;
    if p.is_null() {
        return None;
    }
    let max = GlobalSize(h) / 2;
    let slice = std::slice::from_raw_parts(p, max);
    let end = slice.iter().position(|&c| c == 0).unwrap_or(max);
    let s = String::from_utf16_lossy(&slice[..end]);
    let _ = GlobalUnlock(h);
    Some(s)
}

#[implement(IDropTarget)]
struct DropTarget {
    hwnd: HWND,
    info: RefCell<Option<DragInfo>>,
    helper: Option<IDropTargetHelper>,
}

/// The fridge window's drop target. Events go to `super::{on_drag_over, on_drag_leave, on_drop}`.
pub fn make_target(hwnd: HWND) -> IDropTarget {
    // The helper draws Explorer's drag image over the fridge too.
    let helper = unsafe { CoCreateInstance(&CLSID_DragDropHelper, None, CLSCTX_INPROC_SERVER).ok() };
    DropTarget { hwnd, info: RefCell::new(None), helper }.into()
}

impl IDropTarget_Impl for DropTarget_Impl {
    fn DragEnter(
        &self,
        data: Ref<IDataObject>,
        _keys: MODIFIERKEYS_FLAGS,
        pt: &POINTL,
        effect: *mut DROPEFFECT,
    ) -> windows::core::Result<()> {
        let info = data.as_ref().map(read_drag_info).unwrap_or_default();
        unsafe {
            let ok = allowed(*effect);
            let result = to_dropeffect(super::on_drag_over((pt.x, pt.y), &info, ok));
            *effect = result;
            if let (Some(helper), Some(d)) = (self.helper.as_ref(), data.as_ref()) {
                let p = POINT { x: pt.x, y: pt.y };
                let _ = helper.DragEnter(self.hwnd, d, &p, result);
            }
        }
        *self.info.borrow_mut() = Some(info);
        Ok(())
    }

    fn DragOver(&self, _keys: MODIFIERKEYS_FLAGS, pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        let info = self.info.borrow().clone().unwrap_or_default();
        unsafe {
            let result = to_dropeffect(super::on_drag_over((pt.x, pt.y), &info, allowed(*effect)));
            *effect = result;
            if let Some(helper) = self.helper.as_ref() {
                let p = POINT { x: pt.x, y: pt.y };
                let _ = helper.DragOver(&p, result);
            }
        }
        Ok(())
    }

    fn DragLeave(&self) -> windows::core::Result<()> {
        *self.info.borrow_mut() = None;
        super::on_drag_leave();
        if let Some(helper) = self.helper.as_ref() {
            unsafe {
                let _ = helper.DragLeave();
            }
        }
        Ok(())
    }

    fn Drop(&self, data: Ref<IDataObject>, _keys: MODIFIERKEYS_FLAGS, pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        let stored = self.info.borrow_mut().take();
        let info = data.as_ref().map(read_drag_info).or(stored).unwrap_or_default();
        unsafe {
            let result = to_dropeffect(super::on_drop((pt.x, pt.y), &info, allowed(*effect)));
            *effect = result;
            if let (Some(helper), Some(d)) = (self.helper.as_ref(), data.as_ref()) {
                let p = POINT { x: pt.x, y: pt.y };
                let _ = helper.Drop(d, &p, result);
            }
        }
        Ok(())
    }
}

#[implement(IDropSource)]
struct DropSource;

impl IDropSource_Impl for DropSource_Impl {
    fn QueryContinueDrag(&self, escape: BOOL, keys: MODIFIERKEYS_FLAGS) -> HRESULT {
        if escape.as_bool() {
            DRAGDROP_S_CANCEL
        } else if keys.0 & MK_LBUTTON.0 == 0 {
            DRAGDROP_S_DROP
        } else {
            S_OK
        }
    }

    fn GiveFeedback(&self, _effect: DROPEFFECT) -> HRESULT {
        DRAGDROP_S_USEDEFAULTCURSORS
    }
}

/// A shell data object for one file, as Explorer makes it (so any target can move or copy it).
unsafe fn data_object_for(path: &Path) -> Option<IDataObject> {
    let p = wide_path(path);
    let mut pidl: *mut ITEMIDLIST = std::ptr::null_mut();
    SHParseDisplayName(windows::core::PCWSTR(p.as_ptr()), None, &mut pidl, 0, None).ok()?;
    if pidl.is_null() {
        return None;
    }
    let child = ILClone(ILFindLastID(pidl));
    let parent = ILClone(pidl);
    ILFree(Some(pidl));
    let _ = ILRemoveLastID(Some(parent));
    let items = [child as *const ITEMIDLIST];
    let data: Option<IDataObject> = SHCreateDataObject(Some(parent as *const _), Some(&items), None::<&IDataObject>).ok();
    ILFree(Some(child));
    ILFree(Some(parent));
    data
}

/// A drag image from the item's icon, centred on the pointer. Best effort.
unsafe fn set_drag_image(data: &IDataObject, icon: &Image, px: i32) {
    let Ok(helper) = CoCreateInstance::<_, IDragSourceHelper>(&CLSID_DragDropHelper, None, CLSCTX_INPROC_SERVER) else { return };
    let (w, h) = (px.max(16), px.max(16));
    let info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w,
            biHeight: -h,
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let mut bits = std::ptr::null_mut();
    let Ok(bitmap) = CreateDIBSection(None, &info, DIB_RGB_COLORS, &mut bits, None, 0) else { return };
    let mut rgba = vec![0u8; (w * h * 4) as usize];
    crate::resample::resample(&icon.data, icon.width, icon.height, &mut rgba, w as u32, h as u32);
    let dst = std::slice::from_raw_parts_mut(bits as *mut u8, rgba.len());
    for (d, s) in dst.chunks_mut(4).zip(rgba.chunks(4)) {
        d.copy_from_slice(&[s[2], s[1], s[0], s[3]]);
    }
    let image = SHDRAGIMAGE {
        sizeDragImage: SIZE { cx: w, cy: h },
        ptOffset: POINT { x: w / 2, y: h / 2 },
        hbmpDragImage: bitmap,
        crColorKey: COLORREF(0xFFFF_FFFF),
    };
    // On success the helper owns the bitmap.
    if helper.InitializeFromBitmap(&image, data).is_err() {
        let _ = DeleteObject(bitmap.into());
    }
}

/// Runs a shell drag of `path` (move or copy) and returns when it is over. The caller must not
/// hold the app state: the drag loop dispatches messages.
pub fn drag_out(path: &Path, icon: Option<&Image>, image_px: i32) -> DROPEFFECT {
    unsafe {
        let Some(data) = data_object_for(path) else { return DROPEFFECT_NONE };
        if let Some(icon) = icon {
            set_drag_image(&data, icon, image_px);
        }
        let source: IDropSource = DropSource.into();
        let mut effect = DROPEFFECT_NONE;
        let _ = DoDragDrop(&data, &source, DROPEFFECT_MOVE | DROPEFFECT_COPY, &mut effect);
        effect
    }
}

/// Files directly on the Desktop, for reading icon positions.
pub fn on_desktop(file: &Path, desktop: &Path) -> bool {
    file.parent().map(|p| fridge_core::store::same_path(p, desktop)).unwrap_or(false)
}
