use crate::core::*;
use crate::watcher::command_output;
use serde_json::{json, Value};
use std::{fs, path::{Path,PathBuf}, process::{Child,Command}, thread, time::{Duration,Instant}};

pub fn run(program: &str, args: &[&str]) -> Result<String> {
    // unzip can emit locale-sanitized non-UTF-8 names. Its ASCII path structure
    // is used for validation; ditto extracts the original archive entry bytes.
    Ok(String::from_utf8_lossy(&command_output(program,args,Duration::from_secs(15))?).into_owned())
}
pub fn bundle(executable: &Path) -> Option<PathBuf> {
    let app = executable.parent()?.parent()?.parent()?;
    (app.extension().is_some_and(|s|s == "app")).then(||app.to_owned())
}
pub fn default_directory(executable: &Path, home: &Path) -> PathBuf {
    let Some(app) = bundle(executable) else { return home.join("Library/Application Support/NameGuard"); };
    let parent = app.parent().unwrap();
    let root = if parent.file_name().is_some_and(|n| n == "Applications") && parent != Path::new("/Applications") { parent.parent().unwrap() } else { home };
    root.join("Library/Application Support").join(if app.file_name().unwrap() == "NameGuard Desktop.app" { "NameGuardDesktop" } else { "NameGuard" })
}
pub struct Login { pub executable:PathBuf, pub directory:PathBuf, pub home:PathBuf }
impl Login {
    pub fn label(&self) -> &str { if self.directory.file_name().is_some_and(|s|s == "NameGuard") { "local.nameguard.agent" } else { "local.nameguard.desktop.agent" } }
    pub fn target(&self) -> String { format!("gui/{}/{}",unsafe{libc::getuid()},self.label()) }
    pub fn agent(&self) -> PathBuf { self.home.join("Library/LaunchAgents").join(format!("{}.plist",self.label())) }
    pub fn enabled(&self) -> bool {
        let Ok(plist::Value::Dictionary(value)) = plist::Value::from_file(self.agent()) else {return false;};
        if value.get("Label").and_then(plist::Value::as_string) != Some(self.label()) || value.get("RunAtLoad").and_then(plist::Value::as_boolean) != Some(true) {return false;}
        let arguments = value.get("ProgramArguments").and_then(plist::Value::as_array).map(|a| a.iter().filter_map(plist::Value::as_string).collect::<Vec<_>>());
        let exe = self.executable.to_string_lossy(); let state = self.directory.to_string_lossy();
        if arguments != Some(vec![exe.as_ref(),"--menu","--state-dir",state.as_ref()]) { return false; }
        run("/bin/launchctl", &["print-disabled",&format!("gui/{}",unsafe{libc::getuid()})]).is_ok_and(|s| !s.contains(&format!("\"{}\" => true",self.label())))
    }
    pub fn set(&self, enabled:bool) -> Result<()> {
        fs::create_dir_all(&self.directory)?;
        if enabled {
            let agent = self.agent(); fs::create_dir_all(agent.parent().unwrap())?;
            let value = json!({"Label":self.label(),"ProgramArguments":[self.executable,"--menu","--state-dir",self.directory],"RunAtLoad":true,"KeepAlive":{"SuccessfulExit":false},"ThrottleInterval":60,"ProcessType":"Interactive","LowPriorityIO":true,"StandardOutPath":self.directory.join("launchd.stdout.log"),"StandardErrorPath":self.directory.join("launchd.stderr.log")});
            let mut bytes = vec![]; plist::to_writer_xml(&mut bytes,&value)?; atomic(&agent,&bytes)?;
            run("/bin/launchctl",&["enable",&self.target()])?;
        } else {
            run("/bin/launchctl",&["disable",&self.target()])?;
            if self.agent().exists() { fs::remove_file(self.agent())?; }
        }
        save_json(&self.directory.join("login.json"),&json!({"enabled":enabled}))
    }
    pub fn ensure(&self) -> Result<()> {
        if bundle(&self.executable).and_then(|b|b.parent().map(Path::to_owned)) == Some(self.home.join("Applications")) && !self.directory.join("login.json").exists() { self.set(true)?; }
        Ok(())
    }
}
pub struct Session {
    pub directory:PathBuf, pub config_path:PathBuf, pub executable:PathBuf, pub paused:bool,
    child:Option<Child>, _lock:fs::File, pub error:String, previous:u64,
}
impl Session {
    pub fn start(executable:PathBuf, directory:PathBuf, config_path:PathBuf) -> Result<Self> {
        fs::create_dir_all(&directory)?; let guard = lock(&directory.join("menu.lock"))?;
        if !config_path.exists() { let config = Configuration{roots:Some(vec![home().join("Desktop").to_string_lossy().into_owned()]),..Default::default()}; save_json(&config_path,&config)?; }
        Configuration::load(&config_path)?;
        let paused = read_json(&directory.join("menu.json"))["paused"].as_bool().unwrap_or(false);
        let mut result = Self{ directory,config_path,executable,paused,child:None,_lock:guard,error:String::new(),previous:0 };
        if !paused {result.launch()?;} Ok(result)
    }
    fn launch(&mut self) -> Result<()> {
        Configuration::load(&self.config_path)?;
        use std::os::unix::fs::OpenOptionsExt;
        let output = fs::OpenOptions::new().create(true).append(true).mode(0o600).open(self.directory.join("menu-worker.log"))?;
        self.child = Some(Command::new(&self.executable).arg("--watch").arg("--config").arg(&self.config_path).arg("--state-dir").arg(&self.directory).arg("--parent-pid").arg(std::process::id().to_string()).stdout(output.try_clone()?).stderr(output).spawn()?);
        self.error.clear(); Ok(())
    }
    pub fn healthy(&mut self) -> bool { self.paused || self.child.as_mut().is_some_and(|p|matches!(p.try_wait(),Ok(None))) }
    pub fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let status = read_json(&self.directory.join("status.json"));
            if status["pid"].as_u64() == Some(child.id() as u64) { self.previous += status["renamedThisRun"].as_u64().unwrap_or(0); }
            if child.try_wait().ok().flatten().is_none() {
                unsafe { libc::kill(child.id() as i32,libc::SIGTERM); }
                let start = Instant::now();
                while child.try_wait().ok().flatten().is_none() && start.elapsed() < Duration::from_secs(10) { thread::sleep(Duration::from_millis(50)); }
                if child.try_wait().ok().flatten().is_none() {let _ = child.kill();} let _ = child.wait();
            }
        }
    }
    pub fn toggle_pause(&mut self) -> Result<()> {
        self.stop(); let value = !self.paused;
        save_json(&self.directory.join("menu.json"),&json!({"paused":value}))?;
        self.paused = value; if !value {self.launch()?;} Ok(())
    }
    pub fn restart(&mut self) -> Result<()> { self.stop(); save_json(&self.directory.join("menu.json"),&json!({"paused":false}))?; self.paused = false; self.launch() }
    pub fn change_roots(&mut self, adding:Vec<PathBuf>, removing:Option<PathBuf>) -> Result<()> {
        let mut config = Configuration::load(&self.config_path)?;
        let mut roots = config.roots.take().unwrap_or_else(||config.discover().iter().map(|p|p.to_string_lossy().into_owned()).collect());
        if let Some(path) = removing {roots.retain(|p|Path::new(p) != path);}
        for path in adding {
            let path = physical(&path); if !path.is_dir() {return Err(error("폴더를 찾을 수 없습니다."));}
            let path = path.to_string_lossy().into_owned(); if !roots.contains(&path) {roots.push(path);}
        }
        config.roots = Some(roots); self.stop();
        if let Err(e) = save_json(&self.config_path,&config) {if !self.paused {let _ = self.launch();}return Err(e);}
        if !self.paused {self.launch()?;} Ok(())
    }
    pub fn snapshot(&mut self) -> Value {
        let mut value = read_json(&self.directory.join("status.json"));
        let running = self.child.as_mut().and_then(|p| if p.try_wait().ok().flatten().is_none() {Some(p.id() as u64)} else {None});
        let fresh = value["updated"].as_str().and_then(|s|time::OffsetDateTime::parse(s,&time::format_description::well_known::Rfc3339).ok()).is_some_and(|date| (time::OffsetDateTime::now_utc()-date).whole_seconds() <= 15);
        let title = if !self.error.is_empty() {"오류 확인 필요"} else if self.paused {"일시중지"} else if running.is_none() {"감시 중단"} else if value["pid"].as_u64() != running {"시작 중"} else if !fresh {"응답 확인 필요"} else if value["paused"].as_str().is_some_and(|s|!s.is_empty()) {"변경 보류"} else if value["scanRetriesRemaining"].as_u64().unwrap_or(0)+value["pendingErrors"].as_u64().unwrap_or(0)>0 {"오류 확인 필요"} else if value["roots"].as_array().is_some_and(Vec::is_empty) {"폴더를 선택해 주세요"} else if value["scanDirectoriesRemaining"].as_u64().unwrap_or(0)>0 {"검사 중"} else {"감시 중"};
        value["title"] = title.into(); value["renamedThisRun"] = (self.previous + if self.paused {0} else {value["renamedThisRun"].as_u64().unwrap_or(0)}).into();
        let config = Configuration::load(&self.config_path).ok();
        if let Some(roots) = config.and_then(|c|c.roots) {value["roots"] = json!(roots);}
        if !self.error.is_empty() {value["detail"] = self.error.clone().into();} else {value["detail"] = value["paused"].clone();}
        value
    }
}
impl Drop for Session {fn drop(&mut self) {self.stop();}}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn direct_installed_app_reads_existing_state() {
        assert_eq!(default_directory(Path::new("/Users/a/Applications/NameGuard Desktop.app/Contents/MacOS/nameguard"),Path::new("/Users/other")),PathBuf::from("/Users/a/Library/Application Support/NameGuardDesktop"));
        assert_eq!(default_directory(Path::new("/Users/a/Applications/NameGuard.app/Contents/MacOS/nameguard"),Path::new("/Users/a")),PathBuf::from("/Users/a/Library/Application Support/NameGuard"));
    }
    #[test] fn native_worker_lifecycle_and_cancelled_removed_root() -> Result<()> {
        let Ok(binary)=std::env::var("NAMEGUARD_TEST_BINARY") else {return Ok(());};
        let temp=tempfile::tempdir()?;let a=temp.path().join("a");let b=temp.path().join("b");let state=temp.path().join("state");fs::create_dir_all(&a)?;fs::create_dir_all(&b)?;fs::create_dir_all(&state)?;
        let config=Configuration{roots:Some(vec![a.to_string_lossy().into_owned()]),quiet_seconds:3.,directory_quiet_seconds:3.,protected_apps:vec![],..Default::default()};
        let path=state.join("config.json");save_json(&path,&config)?;
        let held=a.join("한.txt");fs::write(&held,b"keep")?;
        let mut session=Session::start(binary.into(),state.clone(),path.clone())?;
        let wait=|predicate:&mut dyn FnMut()->bool| -> Result<()> {let deadline=Instant::now()+Duration::from_secs(25);while Instant::now()<deadline {if predicate(){return Ok(());}thread::sleep(Duration::from_millis(100));}Err(error("Lifecycle wait timed out"))};
        wait(&mut ||session.snapshot()["pending"].as_u64().unwrap_or(0)>0)?;
        session.change_roots(vec![],Some(a.clone()))?;thread::sleep(Duration::from_secs(4));
        assert!(directory_names(&a)?.iter().any(|s|s.to_str()==Some("한.txt")));
        assert_eq!(Configuration::load(&path)?.roots,Some(vec![]));
        session.change_roots(vec![b.clone()],None)?;fs::write(b.join("한.txt"),b"new")?;
        wait(&mut ||directory_names(&b).is_ok_and(|n|n.iter().any(|s|s.to_str()==Some("한.txt"))))?;
        session.toggle_pause()?;fs::write(b.join("글.txt"),b"paused")?;thread::sleep(Duration::from_secs(4));
        assert!(directory_names(&b)?.iter().any(|s|s.to_str()==Some("글.txt")));
        session.toggle_pause()?;wait(&mut ||directory_names(&b).is_ok_and(|n|n.iter().any(|s|s.to_str()==Some("글.txt"))))?;
        session.stop();assert_eq!(session.snapshot()["title"],"감시 중단");Ok(())
    }
    #[test] fn real_login_startup_twice_and_disable_keeps_running() -> Result<()> {
        let Ok(binary)=std::env::var("NAMEGUARD_TEST_BINARY") else {return Ok(());};
        let temp=tempfile::tempdir()?;let state=temp.path().join("Library/Application Support/NameGuardDesktop");fs::create_dir_all(&state)?;
        save_json(&state.join("config.json"),&json!({"roots":[],"protectedApps":[]}))?;
        let pause=b"{\"paused\":true}";fs::write(state.join("menu.json"),pause)?;
        let login=Login{executable:binary.into(),directory:state.clone(),home:temp.path().to_owned()};
        let result=(|| -> Result<()> {
            run("/bin/launchctl",&["disable",&login.target()])?;
            for cycle in 0..2 {
                login.set(true)?;assert!(login.enabled());
                run("/bin/launchctl",&["bootstrap",&format!("gui/{}",unsafe{libc::getuid()}),&login.agent().to_string_lossy()])?;
                thread::sleep(Duration::from_secs(3));assert!(run("/bin/launchctl",&["print",&login.target()])?.contains("state = running"));
                if cycle==1 {login.set(false)?;assert!(run("/bin/launchctl",&["print",&login.target()])?.contains("state = running"));}
                run("/bin/launchctl",&["bootout",&login.target()])?;
                let deadline=Instant::now()+Duration::from_secs(15);while Instant::now()<deadline && run("/bin/launchctl",&["print",&login.target()]).is_ok(){thread::sleep(Duration::from_millis(200));}
            }
            login.set(false)?;assert!(!login.enabled());assert_eq!(fs::read(state.join("menu.json"))?,pause);Ok(())
        })();
        let _=run("/bin/launchctl",&["bootout",&login.target()]);let _=run("/bin/launchctl",&["enable",&login.target()]);result
    }
}
