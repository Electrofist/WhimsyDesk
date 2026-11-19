//! File helpers: paths, unique names, and moving files without ever losing one.
//! Same behaviour as the helpers in `windows/fridge/core/src/store.rs`.

use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};

pub fn file_name(p: &Path) -> String {
    p.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Lexically cleans a path (drops "." and resolves ".."), like `standardizedFileURL`.
pub fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn key(p: &Path) -> Vec<String> {
    normalize(p)
        .components()
        .map(|c| {
            let s = c.as_os_str().to_string_lossy().into_owned();
            if cfg!(windows) {
                s.to_lowercase()
            } else {
                s
            }
        })
        .collect()
}

/// Path equality, case-insensitive on Windows.
pub fn same_path(a: &Path, b: &Path) -> bool {
    key(a) == key(b)
}

/// True when `path` is `ancestor` itself or lies somewhere inside it.
pub fn is_inside_or_same(path: &Path, ancestor: &Path) -> bool {
    let (p, a) = (key(path), key(ancestor));
    p.len() >= a.len() && p[..a.len()] == a[..]
}

/// "name.ext", then "name 2.ext", "name 3.ext" and so on, like Finder and Explorer.
pub fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if fs::symlink_metadata(&candidate).is_err() {
        return candidate;
    }
    let path = Path::new(name);
    let base = path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| name.to_string());
    let ext = path
        .extension()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut n = 2;
    loop {
        let numbered = if ext.is_empty() {
            format!("{base} {n}")
        } else {
            format!("{base} {n}.{ext}")
        };
        let candidate = dir.join(numbered);
        if fs::symlink_metadata(&candidate).is_err() {
            return candidate;
        }
        n += 1;
    }
}

/// Moves a file or folder. A rename when possible; across drives, copies everything, checks the
/// copy, and only then removes the original. If anything fails, the original stays where it was.
pub fn move_item(from: &Path, to: &Path) -> io::Result<()> {
    match fs::rename(from, to) {
        Ok(()) => Ok(()),
        Err(rename_error) => {
            if fs::symlink_metadata(to).is_ok() {
                return Err(rename_error);
            }
            if let Err(e) = copy_recursive(from, to) {
                let _ = remove_recursive(to);
                return Err(e);
            }
            if !same_size(from, to) {
                let _ = remove_recursive(to);
                return Err(io::Error::other("the copy did not match the original"));
            }
            remove_recursive(from)
        }
    }
}

pub fn copy_recursive(from: &Path, to: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(from)?;
    if meta.is_dir() {
        fs::create_dir(to)?;
        for item in fs::read_dir(from)? {
            let item = item?;
            copy_recursive(&item.path(), &to.join(item.file_name()))?;
        }
        Ok(())
    } else {
        fs::copy(from, to).map(|_| ())
    }
}

fn remove_recursive(p: &Path) -> io::Result<()> {
    if fs::symlink_metadata(p)?.is_dir() {
        fs::remove_dir_all(p)
    } else {
        fs::remove_file(p)
    }
}

fn total_size(p: &Path) -> u64 {
    match fs::symlink_metadata(p) {
        Ok(m) if m.is_dir() => fs::read_dir(p)
            .map(|it| {
                it.filter_map(|e| e.ok())
                    .map(|e| total_size(&e.path()))
                    .sum()
            })
            .unwrap_or(0),
        Ok(m) => m.len(),
        Err(_) => u64::MAX,
    }
}

pub fn same_size(a: &Path, b: &Path) -> bool {
    total_size(a) == total_size(b)
}

/// Write to a temporary file beside the target, then replace the target.
pub fn write_atomic(path: &Path, data: &[u8]) -> io::Result<()> {
    let tmp = path.with_extension("tmp-write");
    fs::write(&tmp, data)?;
    fs::rename(&tmp, path)
}

/// Hidden files stay out of the drawer: names starting with a dot, and on Windows the Hidden attribute.
pub fn is_hidden(path: &Path) -> bool {
    if path
        .file_name()
        .map(|n| n.to_string_lossy().starts_with('.'))
        .unwrap_or(false)
    {
        return true;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
        if let Ok(m) = fs::symlink_metadata(path) {
            return m.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0;
        }
    }
    false
}

/// Windows drops these into folders on its own; they are not the user's things.
pub fn is_system_file(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    n == "desktop.ini" || n == "thumbs.db"
}

#[cfg(test)]
pub(crate) mod testutil {
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU32, Ordering};

    /// A throwaway folder under the system temp dir, removed on drop.
    pub struct TempDir(PathBuf);

    impl TempDir {
        pub fn new() -> Self {
            static N: AtomicU32 = AtomicU32::new(0);
            let p = std::env::temp_dir().join(format!(
                "drawer-core-test-{}-{}",
                std::process::id(),
                N.fetch_add(1, Ordering::SeqCst)
            ));
            std::fs::create_dir_all(&p).unwrap();
            TempDir(p)
        }
        pub fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testutil::TempDir;
    use super::*;

    #[test]
    fn normalize_cleans_dots() {
        assert_eq!(normalize(Path::new("a/./b/../c")), PathBuf::from("a/c"));
    }

    #[test]
    fn inside_or_same() {
        assert!(is_inside_or_same(Path::new("a/b/c"), Path::new("a/b")));
        assert!(is_inside_or_same(Path::new("a/b"), Path::new("a/b")));
        assert!(
            !is_inside_or_same(Path::new("a/bc"), Path::new("a/b")),
            "not a string prefix match"
        );
        assert!(!is_inside_or_same(Path::new("a"), Path::new("a/b")));
    }

    #[test]
    fn unique_names() {
        let d = TempDir::new();
        fs::write(d.path().join("notes"), "x").unwrap();
        assert_eq!(unique_path(d.path(), "notes"), d.path().join("notes 2"));
        fs::write(d.path().join("a.txt"), "x").unwrap();
        fs::write(d.path().join("a 2.txt"), "x").unwrap();
        assert_eq!(unique_path(d.path(), "a.txt"), d.path().join("a 3.txt"));
        assert_eq!(
            unique_path(d.path(), "fresh.txt"),
            d.path().join("fresh.txt")
        );
    }

    #[test]
    fn copy_fallback_keeps_everything() {
        let d = TempDir::new();
        let folder = d.path().join("Copied");
        fs::create_dir_all(folder.join("inner")).unwrap();
        fs::write(folder.join("inner/x.txt"), "hello").unwrap();
        let to = d.path().join("Copy2");
        copy_recursive(&folder, &to).unwrap();
        assert!(same_size(&folder, &to));
        assert_eq!(fs::read_to_string(to.join("inner/x.txt")).unwrap(), "hello");
    }

    #[test]
    fn write_atomic_replaces() {
        let d = TempDir::new();
        let f = d.path().join("i.json");
        write_atomic(&f, b"one").unwrap();
        write_atomic(&f, b"two").unwrap();
        assert_eq!(fs::read(&f).unwrap(), b"two");
        assert!(!d.path().join("i.tmp-write").exists());
    }
}
