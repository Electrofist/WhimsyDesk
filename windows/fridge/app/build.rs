//! Embeds the app icon, the manifest (per-monitor DPI v2, Common Controls 6) and version info
//! into DesktopFridge.exe. Only when building on Windows for Windows: a cross `cargo check`
//! from a Mac has no resource compiler and does not need one.

use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=icon.ico");
    println!("cargo:rerun-if-changed=DesktopFridge.manifest");

    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let host = env::var("HOST").unwrap_or_default();
    if target_os != "windows" {
        return;
    }
    if !host.contains("windows") {
        println!("cargo:warning=not building on Windows: icon, manifest and version info are not embedded");
        return;
    }

    let dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let version = env::var("CARGO_PKG_VERSION").unwrap_or_else(|_| "0.1.0".into());
    let mut parts: Vec<u32> = version.split(['.', '-']).take(3).map(|p| p.parse().unwrap_or(0)).collect();
    parts.resize(3, 0);
    let numeric = format!("{},{},{},0", parts[0], parts[1], parts[2]);
    let escape = |p: PathBuf| p.to_string_lossy().replace('\\', "\\\\");

    // Numbers instead of winver.h names, so no SDK include path is needed:
    // 24 = RT_MANIFEST, 0x40004 = VOS_NT_WINDOWS32, 1 = VFT_APP, 040904B0 = US English, Unicode.
    let rc = format!(
        r#"1 ICON "{icon}"
1 24 "{manifest}"
1 VERSIONINFO
FILEVERSION {numeric}
PRODUCTVERSION {numeric}
FILEFLAGSMASK 0x3F
FILEFLAGS 0
FILEOS 0x40004
FILETYPE 1
FILESUBTYPE 0
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "CompanyName", "WhimsyDesk"
      VALUE "FileDescription", "Desktop Fridge"
      VALUE "FileVersion", "{version}"
      VALUE "InternalName", "DesktopFridge"
      VALUE "LegalCopyright", "MIT License"
      VALUE "OriginalFilename", "DesktopFridge.exe"
      VALUE "ProductName", "Desktop Fridge"
      VALUE "ProductVersion", "{version}"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
"#,
        icon = escape(dir.join("icon.ico")),
        manifest = escape(dir.join("DesktopFridge.manifest")),
    );
    let rc_path = out.join("desktop-fridge.rc");
    fs::write(&rc_path, rc).expect("write resource script");
    embed_resource::compile(&rc_path, embed_resource::NONE)
        .manifest_required()
        .expect("embed resources");
}
