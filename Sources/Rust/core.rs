use serde::{Deserialize, Serialize};
use std::{collections::HashSet, ffi::CString, fs, io, path::{Path, PathBuf}};
use std::os::unix::{ffi::OsStrExt, fs::{MetadataExt, OpenOptionsExt}};
use unicode_normalization::UnicodeNormalization;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;
pub fn error(s: impl Into<String>) -> Box<dyn std::error::Error + Send + Sync> { io::Error::other(s.into()).into() }
pub fn home() -> PathBuf { std::env::var_os("HOME").map(PathBuf::from).expect("HOME unavailable") }
pub fn nfc(s: &str) -> String { s.nfc().collect() }
pub fn normalized_name(s: &str) -> Option<String> {
    if !s.chars().any(|c| ('\u{1100}'..='\u{11ff}').contains(&c)) { return None; }
    let value = nfc(s);
    (value.as_bytes() != s.as_bytes()).then_some(value)
}
pub fn physical(path: &Path) -> PathBuf { fs::canonicalize(path).unwrap_or_else(|_| path.to_owned()) }
pub fn expand(path: &str) -> PathBuf {
    if path == "~" { home() } else if let Some(tail) = path.strip_prefix("~/") { home().join(tail) } else { path.into() }
}
pub fn atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().ok_or_else(|| error("Invalid state path"))?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(".nameguard-{}", uuid::Uuid::new_v4()));
    let result = (|| -> Result<()> {
        use std::io::Write;
        let mut file = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
        file.write_all(bytes)?; file.sync_all()?;
        fs::rename(&temporary, path)?;
        Ok(())
    })();
    if result.is_err() { let _ = fs::remove_file(temporary); }
    result
}
pub fn save_json(path: &Path, value: &impl Serialize) -> Result<()> { atomic(path, &serde_json::to_vec_pretty(value)?) }
pub fn read_json(path: &Path) -> serde_json::Value {
    fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(serde_json::json!({}))
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Configuration {
    pub roots: Option<Vec<String>>,
    pub quiet_seconds: f64,
    pub directory_quiet_seconds: f64,
    pub excluded_paths: Vec<String>,
    pub protected_apps: Vec<String>,
    #[serde(flatten)] pub extra: serde_json::Map<String, serde_json::Value>,
}
impl Default for Configuration {
    fn default() -> Self { Self {
        roots: None, quiet_seconds: 10., directory_quiet_seconds: 30., excluded_paths: vec![], extra: Default::default(),
        protected_apps: ["Adobe Premiere", "After Effects", "Adobe Media Encoder", "DaVinci Resolve", "Final Cut", "Logic Pro", "Adobe Photoshop", "Adobe Illustrator", "Adobe InDesign", "Lightroom"].iter().map(|s| s.to_string()).collect(),
    }}
}
impl Configuration {
    pub fn load(path: &Path) -> Result<Self> {
        let value: Self = if path.exists() { serde_json::from_slice(&fs::read(path)?)? } else { Self::default() };
        if !value.quiet_seconds.is_finite() || !value.directory_quiet_seconds.is_finite() || value.quiet_seconds < 1. || value.directory_quiet_seconds < value.quiet_seconds {
            return Err(error("설정의 대기 시간이 잘못되었습니다."));
        }
        if value.roots.as_ref().is_some_and(|roots| roots.iter().any(|p| !expand(p).is_absolute() || p.contains('\0'))) {
            return Err(error("감시 폴더는 절대 경로여야 합니다."));
        }
        Ok(value)
    }
    pub fn discover(&self) -> Vec<PathBuf> {
        let mut candidates: Vec<PathBuf> = self.roots.as_ref().map(|r| r.iter().map(|s| expand(s)).collect()).unwrap_or_else(|| vec![home().join("Desktop"), home().join("Dropbox")]);
        if self.roots.is_none() {
            if let Ok(items) = fs::read_dir(home().join("Library/CloudStorage")) {
                for item in items.flatten() {
                    let name = item.file_name().to_string_lossy().into_owned();
                    if name == "Dropbox" || name.starts_with("Dropbox-") || name.starts_with("Dropbox (") { candidates.push(item.path()); }
                }
            }
            if let Some(accounts) = read_json(&home().join(".dropbox/info.json")).as_object() {
                for account in accounts.values() { if let Some(p) = account["path"].as_str() { candidates.push(p.into()); } }
            }
        }
        let mut result: Vec<PathBuf> = vec![];
        for path in candidates {
            let real = physical(&path);
            if !real.is_dir() || result.iter().any(|p| real.starts_with(p)) { continue; }
            result.retain(|p| !p.starts_with(&real)); result.push(real);
        }
        result.sort(); result
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Metadata { pub inode: u64, pub device: u64, pub size: u64, pub modified: i64, pub nanos: i64, pub mode: u32 }
impl Metadata {
    pub fn directory(&self) -> bool { self.mode & libc::S_IFMT as u32 == libc::S_IFDIR as u32 }
    pub fn symlink(&self) -> bool { self.mode & libc::S_IFMT as u32 == libc::S_IFLNK as u32 }
}
pub fn metadata(path: &Path) -> io::Result<Metadata> {
    let m = fs::symlink_metadata(path)?;
    Ok(Metadata { inode: m.ino(), device: m.dev(), size: m.len(), modified: m.mtime(), nanos: m.mtime_nsec(), mode: m.mode() })
}
extern "C" {
    fn renamex_np(from: *const libc::c_char, to: *const libc::c_char, flags: u32) -> libc::c_int;
    fn getiopolicy_np(kind: libc::c_int, scope: libc::c_int) -> libc::c_int;
    fn setiopolicy_np(kind: libc::c_int, scope: libc::c_int, policy: libc::c_int) -> libc::c_int;
}
// Darwin sys/resource.h: VFS_MATERIALIZE_DATALESS_FILES=3, THREAD=1, ON=2.
pub fn directory_names(path: &Path) -> Result<Vec<std::ffi::OsString>> {
    struct Policy(i32);
    impl Drop for Policy { fn drop(&mut self) { unsafe { setiopolicy_np(3, 1, self.0); } } }
    let old = unsafe { getiopolicy_np(3, 1) };
    if old < 0 || unsafe { setiopolicy_np(3, 1, 2) } != 0 { return Err(io::Error::last_os_error().into()); }
    let _restore = Policy(old);
    Ok(fs::read_dir(path)?.map(|entry| entry.map(|e| e.file_name())).collect::<io::Result<_>>()?)
}
#[derive(Debug, PartialEq, Eq)]
pub enum RenameResult { Renamed, Unchanged, Skipped }
pub fn normalize_item(path: &Path) -> Result<RenameResult> {
    let before = metadata(path)?;
    if before.symlink() { return Ok(RenameResult::Skipped); }
    let Some(name) = path.file_name().and_then(|n| n.to_str()) else { return Ok(RenameResult::Skipped); };
    let Some(normal) = normalized_name(name) else { return Ok(RenameResult::Unchanged); };
    let parent = path.parent().ok_or_else(|| error("Invalid filename"))?;
    let destination = parent.join(&normal);
    if let Ok(existing) = metadata(&destination) {
        if existing.inode != before.inode || existing.device != before.device { return Err(io::Error::from_raw_os_error(libc::EEXIST).into()); }
    }
    let from = CString::new(path.as_os_str().as_bytes())?;
    let to = CString::new(destination.as_os_str().as_bytes())?;
    if unsafe { renamex_np(from.as_ptr(), to.as_ptr(), 4) } != 0 { return Err(io::Error::last_os_error().into()); }
    if !directory_names(parent)?.iter().any(|n| n.as_bytes() == normal.as_bytes()) { return Err(error("이 파일 시스템에서는 파일명 정규화를 지원하지 않습니다.")); }
    Ok(RenameResult::Renamed)
}
pub fn excluded(path: &Path, root: &Path) -> bool {
    let Ok(relative) = path.strip_prefix(root) else { return true; };
    if relative.as_os_str().is_empty() { return true; }
    relative.components().any(|part| {
        let name = part.as_os_str().to_string_lossy();
        let ext = Path::new(name.as_ref()).extension().unwrap_or_default().to_string_lossy().to_lowercase();
        name.starts_with('.') || name == "node_modules" || ["app", "bundle", "framework", "photoslibrary", "photolibrary", "fcpbundle", "logicx", "band", "rtfd", "sparsebundle"].contains(&ext.as_str())
    })
}
pub fn is_open(path: &Path, opened: &HashSet<String>) -> bool {
    let path = nfc(&physical(path).to_string_lossy());
    opened.iter().any(|p| p == &path || p.starts_with(&(path.clone() + "/")))
}
pub fn lock(path: &Path) -> Result<fs::File> {
    let file = fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).mode(0o600).open(path)?;
    use std::os::fd::AsRawFd;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 { return Err(error("NameGuard가 이미 실행 중입니다.")); }
    Ok(file)
}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn korean_bytes_only() {
        assert_eq!(normalized_name("한글.txt"), Some("한글.txt".into()));
        for name in ["한글.txt", "hello.txt", "e\u{301}.txt", "ㅎㅏㄴ.txt"] { assert_eq!(normalized_name(name), None); }
    }
    #[test] fn rename_preserves_inode_contents_and_links() -> Result<()> {
        let dir = tempfile::tempdir()?;
        let old = dir.path().join("한글.txt"); fs::write(&old, b"contents untouched")?;
        let before = metadata(&old)?;
        assert_eq!(normalize_item(&old)?, RenameResult::Renamed);
        let new = dir.path().join("한글.txt");
        assert_eq!(directory_names(dir.path())?[0].as_bytes(), "한글.txt".as_bytes());
        assert_eq!(metadata(&new)?.inode, before.inode); assert_eq!(fs::read(&new)?, b"contents untouched");
        assert_eq!(normalize_item(&new)?, RenameResult::Unchanged);
        let link = dir.path().join("링크"); std::os::unix::fs::symlink(&new, &link)?;
        assert_eq!(normalize_item(&link)?, RenameResult::Skipped);
        Ok(())
    }
    #[test] fn collision_never_overwrites() -> Result<()> {
        let dir = tempfile::tempdir()?;
        // APFS aliases NFC/NFD; a case-sensitive filesystem can expose a separate destination.
        let a = dir.path().join("한.txt"); let b = dir.path().join("한.txt"); fs::write(&a, b"first")?;
        if !b.exists() { fs::write(&b, b"second")?; assert!(normalize_item(&a).is_err()); assert_eq!(fs::read(&b)?, b"second"); }
        Ok(())
    }
    #[test] fn open_descendants_and_exclusions() {
        let open = HashSet::from([nfc("/tmp/폴더/movie.mov")]);
        assert!(is_open(Path::new("/tmp/폴더"), &open)); assert!(!is_open(Path::new("/tmp/폴더2"), &open));
        assert!(excluded(Path::new("/root/A.app/한글"), Path::new("/root")));
        assert!(excluded(Path::new("/root/.git/한글"), Path::new("/root")));
        assert!(!excluded(Path::new("/root/폴더/한글.mov"), Path::new("/root")));
    }
    #[test] fn legacy_config_unknown_fields_preserved() -> Result<()> {
        let config: Configuration = serde_json::from_str(r#"{"quietSeconds":17,"futureOption":"keep"}"#)?;
        assert!(config.roots.is_none()); assert_eq!(config.quiet_seconds, 17.);
        assert_eq!(serde_json::to_value(&config)?["futureOption"], "keep"); Ok(())
    }
}
