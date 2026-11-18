//! OLE drag and drop: files dropped onto the drawer.
//!
//! A drop only records what to do; the files are moved after the drop returns (see
//! `super::on_drop`), because the source is still inside its drag loop. The drop answers "no
//! effect" for the files it moves itself, so the source never deletes anything on our behalf.

use super::util::{path_from_wide, wide_path};
use crate::sprite::Sprite;
use std::path::{Path, PathBuf};
use windows::core::{implement, Ref, BOOL, HRESULT};
use windows::Win32::Foundation::{
    COLORREF, DRAGDROP_S_CANCEL, DRAGDROP_S_DROP, DRAGDROP_S_USEDEFAULTCURSORS, HWND, POINT,
    POINTL, SIZE, S_OK,
};
use windows::Win32::Graphics::Gdi::{
    CreateDIBSection, DeleteObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS,
};
use windows::Win32::System::Com::{
    CoCreateInstance, IDataObject, CLSCTX_INPROC_SERVER, DVASPECT_CONTENT, FORMATETC, TYMED_HGLOBAL,
};
use windows::Win32::System::Ole::{
    DoDragDrop, IDropSource, IDropSource_Impl, IDropTarget, IDropTarget_Impl, ReleaseStgMedium,
    CF_HDROP, DROPEFFECT, DROPEFFECT_COPY, DROPEFFECT_MOVE, DROPEFFECT_NONE,
};
use windows::Win32::System::SystemServices::{MK_LBUTTON, MODIFIERKEYS_FLAGS};
use windows::Win32::UI::Shell::Common::ITEMIDLIST;
use windows::Win32::UI::Shell::{
    CLSID_DragDropHelper, DragQueryFileW, IDragSourceHelper, IDropTargetHelper, ILClone,
    ILFindLastID, ILFree, ILRemoveLastID, SHCreateDataObject, SHParseDisplayName, HDROP,
    SHDRAGIMAGE,
};

fn hdrop_format() -> FORMATETC {
    FORMATETC {
        cfFormat: CF_HDROP.0,
        ptd: std::ptr::null_mut(),
        dwAspect: DVASPECT_CONTENT.0,
        lindex: -1,
        tymed: TYMED_HGLOBAL.0 as u32,
    }
}

/// The file paths in a drag (empty for text, pictures and so on).
pub fn read_files(data: &IDataObject) -> Vec<PathBuf> {
    let mut files = Vec::new();
    unsafe {
        if let Ok(mut medium) = data.GetData(&hdrop_format()) {
            let hdrop = HDROP(medium.u.hGlobal.0);
            let count = DragQueryFileW(hdrop, u32::MAX, None);
            for i in 0..count {
                let len = DragQueryFileW(hdrop, i, None) as usize;
                if len == 0 {
                    continue;
                }
                let mut buf = vec![0u16; len + 1];
                DragQueryFileW(hdrop, i, Some(&mut buf));
                files.push(path_from_wide(&buf));
            }
            ReleaseStgMedium(&mut medium);
        }
    }
    files
}

#[implement(IDropTarget)]
struct DropTarget {
    hwnd: HWND,
    has_files: std::cell::Cell<bool>,
    helper: Option<IDropTargetHelper>,
}

/// The drawer window's drop target. Events go to `super::{on_drag_over, on_drag_leave, on_drop}`.
pub fn make_target(hwnd: HWND) -> IDropTarget {
    // The helper draws Explorer's drag image over the drawer too.
    let helper =
        unsafe { CoCreateInstance(&CLSID_DragDropHelper, None, CLSCTX_INPROC_SERVER).ok() };
    DropTarget {
        hwnd,
        has_files: std::cell::Cell::new(false),
        helper,
    }
    .into()
}

impl IDropTarget_Impl for DropTarget_Impl {
    fn DragEnter(
        &self,
        data: Ref<IDataObject>,
        _keys: MODIFIERKEYS_FLAGS,
        pt: &POINTL,
        effect: *mut DROPEFFECT,
    ) -> windows::core::Result<()> {
        let files = data
            .as_ref()
            .map(|d| !read_files(d).is_empty())
            .unwrap_or(false);
        self.has_files.set(files);
        unsafe {
            let result = if super::on_drag_over(files) {
                DROPEFFECT_MOVE
            } else {
                DROPEFFECT_NONE
            };
            *effect = result;
            if let (Some(helper), Some(d)) = (self.helper.as_ref(), data.as_ref()) {
                let p = POINT { x: pt.x, y: pt.y };
                let _ = helper.DragEnter(self.hwnd, d, &p, result);
            }
        }
        Ok(())
    }

    fn DragOver(
        &self,
        _keys: MODIFIERKEYS_FLAGS,
        pt: &POINTL,
        effect: *mut DROPEFFECT,
    ) -> windows::core::Result<()> {
        unsafe {
            let result = if super::on_drag_over(self.has_files.get()) {
                DROPEFFECT_MOVE
            } else {
                DROPEFFECT_NONE
            };
            *effect = result;
            if let Some(helper) = self.helper.as_ref() {
                let p = POINT { x: pt.x, y: pt.y };
                let _ = helper.DragOver(&p, result);
            }
        }
        Ok(())
    }

    fn DragLeave(&self) -> windows::core::Result<()> {
        self.has_files.set(false);
        super::on_drag_leave();
        if let Some(helper) = self.helper.as_ref() {
            unsafe {
                let _ = helper.DragLeave();
            }
        }
        Ok(())
    }

    fn Drop(
        &self,
        data: Ref<IDataObject>,
        _keys: MODIFIERKEYS_FLAGS,
        pt: &POINTL,
        effect: *mut DROPEFFECT,
    ) -> windows::core::Result<()> {
        let files = data.as_ref().map(read_files).unwrap_or_default();
        self.has_files.set(false);
        unsafe {
            // We move the files ourselves afterwards: tell the source nothing happened.
            super::on_drop(files);
            *effect = DROPEFFECT_NONE;
            if let (Some(helper), Some(d)) = (self.helper.as_ref(), data.as_ref()) {
                let p = POINT { x: pt.x, y: pt.y };
                let _ = helper.Drop(d, &p, DROPEFFECT_NONE);
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
    let data: Option<IDataObject> =
        SHCreateDataObject(Some(parent as *const _), Some(&items), None::<&IDataObject>).ok();
    ILFree(Some(child));
    ILFree(Some(parent));
    data
}

/// A drag image from the item's icon (its logical part, without the shadow), centred on the
/// pointer. Best effort.
unsafe fn set_drag_image(data: &IDataObject, icon: &Sprite) {
    let Ok(helper) =
        CoCreateInstance::<_, IDragSourceHelper>(&CLSID_DragDropHelper, None, CLSCTX_INPROC_SERVER)
    else {
        return;
    };
    let (w, h) = (icon.lw as i32, icon.lh as i32);
    if w <= 0 || h <= 0 {
        return;
    }
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
    let Ok(bitmap) = CreateDIBSection(None, &info, DIB_RGB_COLORS, &mut bits, None, 0) else {
        return;
    };
    let dst = std::slice::from_raw_parts_mut(bits as *mut u8, (w * h * 4) as usize);
    for y in 0..icon.lh {
        let from = ((y + icon.oy) * icon.w + icon.ox) * 4;
        dst[y * icon.lw * 4..(y + 1) * icon.lw * 4]
            .copy_from_slice(&icon.data[from..from + icon.lw * 4]);
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
pub fn drag_out(path: &Path, icon: Option<&Sprite>) -> DROPEFFECT {
    unsafe {
        let Some(data) = data_object_for(path) else {
            return DROPEFFECT_NONE;
        };
        if let Some(icon) = icon {
            set_drag_image(&data, icon);
        }
        let source: IDropSource = DropSource.into();
        let mut effect = DROPEFFECT_NONE;
        let _ = DoDragDrop(
            &data,
            &source,
            DROPEFFECT_MOVE | DROPEFFECT_COPY,
            &mut effect,
        );
        effect
    }
}

pub fn accepted(effect: DROPEFFECT) -> bool {
    effect != DROPEFFECT_NONE
}
