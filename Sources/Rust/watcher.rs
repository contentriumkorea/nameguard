use crate::core::*;
use notify::{RecursiveMode, Watcher as _};
use serde_json::{json, Value};
use std::{collections::{HashMap, HashSet, VecDeque}, fs, io::{Read, Write}, path::{Path, PathBuf}, process::{Command, Stdio}, sync::mpsc, thread, time::{Duration, Instant, SystemTime, UNIX_EPOCH}};

pub fn timestamp() -> String { time::OffsetDateTime::now_utc().format(&time::format_description::well_known::Rfc3339).unwrap() }
fn seconds() -> f64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64() }
pub fn log(directory: &Path, event: &str, mut value: Value) {
    value["event"] = event.into(); value["time"] = timestamp().into();
    let path = directory.join("events.jsonl");
    if fs::metadata(&path).is_ok_and(|m| m.len() > 5_000_000) { let _ = fs::rename(&path, path.with_extension("jsonl.1")); }
    use std::os::unix::fs::OpenOptionsExt;
    if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).mode(0o600).open(path) {
        if let Ok(bytes) = serde_json::to_vec(&value) { let _ = file.write_all(&bytes); let _ = file.write_all(b"\n"); }
    }
}
pub fn command_output(program: &str, args: &[&str], timeout: Duration) -> Result<Vec<u8>> {
    let mut child = Command::new(program).args(args).stdout(Stdio::piped()).stderr(Stdio::null()).spawn()?;
    let mut stdout = child.stdout.take().unwrap();
    let reader = thread::spawn(move || { let mut data = vec![]; stdout.read_to_end(&mut data).map(|_| data) });
    let start = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? { break status; }
        if start.elapsed() > timeout { let _ = child.kill(); let _ = child.wait(); let _ = reader.join(); return Err(error("프로세스 응답 시간 초과")); }
        thread::sleep(Duration::from_millis(25));
    };
    let data = reader.join().map_err(|_| error("프로세스 출력 오류"))??;
    if !status.success() { return Err(error(format!("실행 실패: {program}"))); }
    Ok(data)
}
fn open_paths() -> Result<HashSet<String>> {
    let data = command_output("/usr/sbin/lsof", &["-n", "-P", "-F0n", "-u", &unsafe {libc::getuid()}.to_string()], Duration::from_secs(8))?;
    Ok(data.split(|b| *b == 0).filter_map(|field| {
        let field = field.strip_prefix(b"\n").unwrap_or(field);
        let bytes = field.strip_prefix(b"n/")?;
        let path = format!("/{}", String::from_utf8_lossy(bytes));
        Some(nfc(&physical(Path::new(&path)).to_string_lossy()))
    }).collect())
}
#[derive(Clone)] struct Pending { info: Metadata, due: f64, priority: bool }
type ScanResult = (PathBuf, Result<Vec<std::ffi::OsString>>);
pub struct Engine {
    config: Configuration, directory: PathBuf, roots: Vec<PathBuf>, pending: HashMap<PathBuf, Pending>,
    scans: VecDeque<PathBuf>, queued: HashSet<PathBuf>, in_flight: HashSet<PathBuf>, failed: HashMap<PathBuf, f64>,
    scan_tx: mpsc::Sender<ScanResult>, scan_rx: mpsc::Receiver<ScanResult>,
    history: HashMap<String, Vec<f64>>, pending_errors: HashSet<PathBuf>, renamed: u64, failures: u64, pause: String,
}
impl Engine {
    pub fn new(config: Configuration, directory: PathBuf) -> Result<Self> {
        fs::create_dir_all(&directory)?;
        let history = fs::read(directory.join("history.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        let (scan_tx, scan_rx) = mpsc::channel();
        Ok(Self { config, directory, roots: vec![], pending: HashMap::new(), scans: VecDeque::new(), queued: HashSet::new(), in_flight: HashSet::new(), failed: HashMap::new(), scan_tx, scan_rx, history, pending_errors: HashSet::new(), renamed: 0, failures: 0, pause: String::new() })
    }
    fn allowed(&self, path: &Path) -> bool {
        let Some(root) = self.roots.iter().find(|r| path != r.as_path() && path.starts_with(r)) else { return false; };
        if excluded(path, root) || self.config.excluded_paths.iter().any(|p| path.starts_with(expand(p))) { return false; }
        let mut parent = path.parent();
        while let Some(p) = parent {
            if p == root { return true; }
            if !p.starts_with(root) || !metadata(p).is_ok_and(|m| m.directory() && !m.symlink()) { return false; }
            parent = p.parent();
        }
        false
    }
    fn queue_scan(&mut self, path: PathBuf) {
        if self.queued.insert(path.clone()) { self.scans.push_back(path); }
    }
    fn enqueue(&mut self, path: &Path, priority: bool) {
        if !self.allowed(path) { return; }
        let Ok(info) = metadata(path) else { return; };
        if info.symlink() { return; }
        if path.file_name().and_then(|n| n.to_str()).and_then(normalized_name).is_some() {
            // A metadata scan must not indefinitely postpone an unchanged candidate.
            let old = self.pending.get(path);
            if priority || old.is_none() || old.is_some_and(|p| p.info != info) {
                let wait = if info.directory() { self.config.directory_quiet_seconds } else { self.config.quiet_seconds };
                self.pending.insert(path.to_owned(), Pending { info, due: seconds() + wait, priority: priority || old.is_some_and(|p| p.priority) });
            }
        }
        if priority {
            let mut parent = path.parent();
            while let Some(p) = parent {
                if let Some(item) = self.pending.get_mut(p) { item.due = seconds() + self.config.directory_quiet_seconds; }
                parent = p.parent();
            }
        }
    }
    fn actual(&self, path: &Path) -> Option<PathBuf> {
        let parent = path.parent()?; let expected = nfc(path.file_name()?.to_str()?);
        directory_names(parent).ok()?.into_iter().find(|n| n.to_str().is_some_and(|n| nfc(n) == expected)).map(|n| parent.join(n))
    }
    fn event(&mut self, event: notify::Result<notify::Event>) {
        match event {
            Ok(event) => {
                if event.need_rescan() { for root in self.roots.clone() { self.queue_scan(root); } }
                for path in event.paths {
                    if self.roots.contains(&path) { self.queue_scan(path); continue; }
                    let Some(actual) = self.actual(&path) else { continue; };
                    self.enqueue(&actual, true);
                    if metadata(&actual).is_ok_and(|m| m.directory() && !m.symlink()) && self.allowed(&actual) { self.queue_scan(actual); }
                }
            }
            Err(e) => { self.failures += 1; log(&self.directory, "watch_error", json!({"error":e.to_string()})); for r in self.roots.clone() { self.queue_scan(r); } }
        }
    }
    fn pump_scans(&mut self) {
        while let Ok((path, result)) = self.scan_rx.try_recv() {
            self.in_flight.remove(&path);
            match result {
                Ok(names) => {
                    self.failed.remove(&path);
                    // Parent may have been renamed while its listing was in flight.
                    if !path.is_dir() { continue; }
                    for name in names {
                        let child = path.join(name);
                        if !self.allowed(&child) { continue; }
                        self.enqueue(&child, false);
                        if metadata(&child).is_ok_and(|m| m.directory() && !m.symlink()) { self.queue_scan(child); }
                    }
                }
                Err(e) => { self.failures += 1; self.failed.insert(path.clone(), seconds()+300.); log(&self.directory, "scan_error", json!({"path":path,"error":e.to_string()})); }
            }
        }
        for path in self.failed.iter().filter(|(_, due)| **due <= seconds()).map(|(p, _)| p.clone()).collect::<Vec<_>>() { self.failed.remove(&path); self.queue_scan(path); }
        while self.in_flight.len() < 2 {
            let Some(path) = self.scans.pop_front() else { break; }; self.queued.remove(&path);
            if !(self.roots.contains(&path) || self.allowed(&path)) || !metadata(&path).is_ok_and(|m| m.directory() && !m.symlink()) || !self.in_flight.insert(path.clone()) { continue; }
            let tx = self.scan_tx.clone();
            thread::spawn(move || { let result = directory_names(&path); let _ = tx.send((path, result)); });
        }
    }
    fn status(&self) {
        let _ = save_json(&self.directory.join("status.json"), &json!({"updated":timestamp(),"pid":std::process::id(),"roots":self.roots,"pending":self.pending.len(),"renamedThisRun":self.renamed,"errorsThisRun":self.failures,"scanDirectoriesRemaining":self.scans.len()+self.in_flight.len(),"scanRetriesRemaining":self.failed.len(),"pendingErrors":self.pending_errors.len(),"paused":self.pause,"mode":"watch"}));
    }
    fn tick(&mut self) {
        self.pump_scans();
        let now = seconds();
        let mut due: Vec<_> = self.pending.iter().filter(|(_, p)| p.due <= now).map(|(path,p)| (path.clone(),p.clone())).collect();
        due.sort_by(|(a,x),(b,y)| y.priority.cmp(&x.priority).then(x.due.total_cmp(&y.due)).then(b.components().count().cmp(&a.components().count())));
        if due.is_empty() { if self.pending.is_empty() { self.pause.clear(); } self.status(); return; }
        let busy = crate::ui::running_applications().into_iter().filter(|name| self.config.protected_apps.iter().any(|p| name.to_lowercase().contains(&p.to_lowercase()))).collect::<Vec<_>>();
        if !busy.is_empty() { self.pause = format!("편집 프로그램 실행 중: {}", busy.join(", ")); self.status(); return; }
        let opened = match open_paths() { Ok(p) => p, Err(e) => { self.pause = format!("열린 파일 확인 실패: {e}"); self.status(); return; } };
        self.pause.clear();
        for (key, item) in due.into_iter().take(100) {
            let Some(path) = self.actual(&key).filter(|p| self.allowed(p)) else { self.pending.remove(&key); self.pending_errors.remove(&key); continue; };
            let Ok(info) = metadata(&path) else { self.pending.remove(&key); continue; };
            if path.file_name().and_then(|n| n.to_str()).and_then(normalized_name).is_none() { self.pending.remove(&key); self.pending_errors.remove(&key); continue; }
            if info != item.info { self.pending.remove(&key); self.enqueue(&path, false); continue; }
            if is_open(&path, &opened) { if let Some(p) = self.pending.get_mut(&key) { p.due = now+30.; } self.pause = "열린 파일 사용 중".into(); continue; }
            let identity = format!("{}:{}", info.device, info.inode);
            let recent: Vec<f64> = self.history.get(&identity).into_iter().flatten().copied().filter(|t| now-t < 3600.).collect();
            if recent.len() >= 3 {
                if let Some(p) = self.pending.get_mut(&key) { p.due = recent[0]+3601.; }
                self.pause = "동기화 반복 감지 · 잠시 보류".into(); log(&self.directory, "cooldown", json!({"path":path})); continue;
            }
            if metadata(&path).ok().as_ref() != Some(&info) { self.pending.remove(&key); self.enqueue(&path, false); continue; }
            match normalize_item(&path) {
                Ok(result) => {
                    self.pending.remove(&key); self.pending_errors.remove(&key);
                    if result == RenameResult::Renamed {
                        self.renamed += 1; let mut history = recent; history.push(now); self.history.insert(identity, history);
                        log(&self.directory, "renamed", json!({"from":path,"inode":info.inode}));
                        // A directory rename invalidates descendant paths. Rescan its new subtree.
                        if info.directory() { if let Some(new) = self.actual(&path) { self.queue_scan(new); } }
                    }
                }
                Err(e) => { self.failures += 1; self.pending_errors.insert(key.clone()); if let Some(p) = self.pending.get_mut(&key) { p.due = now+300.; } log(&self.directory,"rename_error",json!({"path":path,"error":e.to_string()})); }
            }
        }
        self.history.retain(|_, h| h.iter().any(|t| now-t < 3600.));
        let _ = save_json(&self.directory.join("history.json"), &self.history); self.status();
    }
    pub fn run(mut self, parent: Option<i32>) -> Result<()> {
        let _lock = lock(&self.directory.join("daemon.lock"))?;
        let (tx, rx) = mpsc::sync_channel(4096);
        let overflow = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let dropped = overflow.clone();
        let mut watcher = notify::recommended_watcher(move |e| { if tx.try_send(e).is_err() { dropped.store(true, std::sync::atomic::Ordering::Relaxed); } })?;
        self.roots = self.config.discover();
        for r in self.roots.clone() { watcher.watch(&r, RecursiveMode::Recursive)?; self.queue_scan(r); }
        if self.config.roots.is_none() && home().join("Library/CloudStorage").is_dir() { let _ = watcher.watch(&home().join("Library/CloudStorage"), RecursiveMode::Recursive); }
        log(&self.directory, "started", json!({"pid":std::process::id(),"roots":self.roots})); self.status();
        let mut discovery = Instant::now(); let mut tick = Instant::now()-Duration::from_secs(2);
        loop {
            if parent.is_some_and(|pid| unsafe {libc::getppid()} != pid) || crate::STOP.load(std::sync::atomic::Ordering::Relaxed) { break; }
            if let Ok(event) = rx.recv_timeout(Duration::from_millis(100)) { self.event(event); }
            for event in rx.try_iter().take(1000) { self.event(event); }
            if overflow.swap(false, std::sync::atomic::Ordering::Relaxed) { for r in self.roots.clone() { self.queue_scan(r); } }
            if discovery.elapsed() >= Duration::from_secs(60) {
                discovery = Instant::now();
                let roots = self.config.discover();
                for r in self.roots.clone() { if !roots.contains(&r) { let _ = watcher.unwatch(&r); } }
                for r in &roots { if !self.roots.contains(r) { watcher.watch(r,RecursiveMode::Recursive)?; self.queue_scan(r.clone()); } }
                self.roots = roots;
            }
            self.pump_scans();
            if tick.elapsed() >= Duration::from_secs(2) { tick = Instant::now(); self.tick(); }
        }
        Ok(())
    }
    pub fn audit(mut self) -> Result<u64> {
        self.roots = self.config.discover(); let mut todo = self.roots.clone(); let mut count = 0;
        while let Some(path) = todo.pop() {
            match directory_names(&path) {
                Ok(names) => for name in names {
                    let child = path.join(name); if !self.allowed(&child) { continue; }
                    let Ok(info) = metadata(&child) else { continue; }; if info.symlink() { continue; }
                    if child.file_name().and_then(|s|s.to_str()).and_then(normalized_name).is_some() { count += 1; }
                    if info.directory() { todo.push(child); }
                },
                Err(e) => { self.failures += 1; log(&self.directory,"scan_error",json!({"path":path,"error":e.to_string()})); }
            }
        }
        println!("Roots: {:?}\nNFD Korean candidates: {count}\nScan errors: {}", self.roots, self.failures); Ok(self.failures)
    }
}
