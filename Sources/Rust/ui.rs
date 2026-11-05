#![allow(unexpected_cfgs)]
use crate::{
    core::*,
    services::{Login, Session},
    update,
};
use objc::{
    class,
    declare::ClassDecl,
    msg_send,
    runtime::{Object, Sel, BOOL, NO, YES},
    sel, sel_impl,
};
use std::{
    cell::RefCell,
    ffi::CStr,
    path::{Path, PathBuf},
    sync::{atomic::Ordering, mpsc},
    thread,
};
type Id = *mut Object;
const NIL: Id = std::ptr::null_mut();
#[link(name = "AppKit", kind = "framework")]
extern "C" {}
#[link(name = "Foundation", kind = "framework")]
extern "C" {}

// All AppKit objects live on the main thread. Only owned paths/results cross worker threads.
unsafe fn string(value: &str) -> Id {
    let object: Id = msg_send![class!(NSString), alloc];
    let object: Id =
        msg_send![object,initWithBytes:value.as_ptr() length:value.len() encoding:4usize];
    msg_send![object, autorelease]
}
unsafe fn text(value: Id) -> String {
    if value.is_null() {
        return String::new();
    }
    let pointer: *const libc::c_char = msg_send![value, UTF8String];
    if pointer.is_null() {
        String::new()
    } else {
        CStr::from_ptr(pointer).to_string_lossy().into_owned()
    }
}
pub fn running_applications() -> Vec<String> {
    unsafe {
        let pool: Id = msg_send![class!(NSAutoreleasePool), new];
        let workspace: Id = msg_send![class!(NSWorkspace), sharedWorkspace];
        let apps: Id = msg_send![workspace, runningApplications];
        let count: usize = msg_send![apps, count];
        let mut result = vec![];
        for i in 0..count {
            let app: Id = msg_send![apps,objectAtIndex:i];
            let name: Id = msg_send![app, localizedName];
            result.push(text(name));
        }
        let _: () = msg_send![pool, drain];
        result
    }
}
pub fn alert(title: &str, detail: &str, buttons: &[&str]) -> isize {
    unsafe {
        let app: Id = msg_send![class!(NSApplication), sharedApplication];
        let _: () = msg_send![app,activateIgnoringOtherApps:YES];
        let alert: Id = msg_send![class!(NSAlert), new];
        let _: () = msg_send![alert,setMessageText:string(title)];
        let _: () = msg_send![alert,setInformativeText:string(detail)];
        for button in buttons {
            let _: Id = msg_send![alert,addButtonWithTitle:string(button)];
        }
        let response: isize = msg_send![alert, runModal];
        let _: () = msg_send![alert, release];
        response
    }
}
unsafe fn choose_folders() -> Vec<PathBuf> {
    let app: Id = msg_send![class!(NSApplication), sharedApplication];
    let _: () = msg_send![app,activateIgnoringOtherApps:YES];
    let panel: Id = msg_send![class!(NSOpenPanel), openPanel];
    let _: () = msg_send![panel,setTitle:string("감시할 폴더 선택")];
    let _: () = msg_send![panel,setPrompt:string("추가")];
    let _: () = msg_send![panel,setCanChooseFiles:NO];
    let _: () = msg_send![panel,setCanChooseDirectories:YES];
    let _: () = msg_send![panel,setAllowsMultipleSelection:YES];
    let result: isize = msg_send![panel, runModal];
    if result != 1 {
        return vec![];
    }
    let urls: Id = msg_send![panel, URLs];
    let count: usize = msg_send![urls, count];
    (0..count)
        .map(|i| {
            let url: Id = msg_send![urls,objectAtIndex:i];
            let path: Id = msg_send![url, path];
            PathBuf::from(text(path))
        })
        .collect()
}
fn open_url(url: &str) {
    unsafe {
        let workspace: Id = msg_send![class!(NSWorkspace), sharedWorkspace];
        let url: Id = msg_send![class!(NSURL),URLWithString:string(url)];
        let _: BOOL = msg_send![workspace,openURL:url];
    }
}
fn open_folder(path: &Path) {
    unsafe {
        let workspace: Id = msg_send![class!(NSWorkspace), sharedWorkspace];
        let url: Id = msg_send![class!(NSURL),fileURLWithPath:string(&path.to_string_lossy())];
        let _: BOOL = msg_send![workspace,openURL:url];
    }
}
enum Message {
    Checked(Result<Option<update::Release>>),
    Prepared(Result<update::Staged>),
}
struct App {
    session: Session,
    login: Login,
    item: Id,
    menu: Id,
    target: Id,
    updating: bool,
    rx: Option<mpsc::Receiver<Message>>,
    health: Option<PathBuf>,
    health_done: bool,
}
thread_local! {static APP:RefCell<Option<App>>=const {RefCell::new(None)};}
unsafe fn add(menu: Id, target: Id, title: &str, tag: isize, enabled: bool) -> Id {
    let item: Id = msg_send![class!(NSMenuItem), alloc];
    let item: Id =
        msg_send![item,initWithTitle:string(title) action:sel!(action:) keyEquivalent:string("")];
    let _: () = msg_send![item,setTag:tag];
    let _: () = msg_send![item,setTarget:target];
    let _: () = msg_send![item,setEnabled:if enabled {YES}else{NO}];
    let _: () = msg_send![menu,addItem:item];
    let _: () = msg_send![item, release];
    item
}
unsafe fn separator(menu: Id) {
    let item: Id = msg_send![class!(NSMenuItem), separatorItem];
    let _: () = msg_send![menu,addItem:item];
}
impl App {
    unsafe fn refresh(&mut self) {
        let snapshot = self.session.snapshot();
        let _: () = msg_send![self.menu, removeAllItems];
        let title = snapshot["title"].as_str().unwrap_or("시작 중");
        add(
            self.menu,
            self.target,
            &format!("NameGuard {} · {title}", env!("CARGO_PKG_VERSION")),
            0,
            false,
        );
        add(
            self.menu,
            self.target,
            &format!(
                "이번 실행 {}건 처리 · {}건 대기",
                snapshot["renamedThisRun"].as_u64().unwrap_or(0),
                snapshot["pending"].as_u64().unwrap_or(0)
            ),
            0,
            false,
        );
        if let Some(detail) = snapshot["detail"].as_str().filter(|s| !s.is_empty()) {
            add(self.menu, self.target, detail, 0, false);
        }
        separator(self.menu);
        add(
            self.menu,
            self.target,
            "감시 폴더 (하위 폴더 포함)",
            0,
            false,
        );
        if let Some(roots) = snapshot["roots"].as_array() {
            for root in roots.iter().filter_map(|r| r.as_str()) {
                let parent = add(self.menu, self.target, root, 0, true);
                let submenu: Id = msg_send![class!(NSMenu), new];
                let _: () = msg_send![submenu,setAutoenablesItems:NO];
                let remove = add(submenu, self.target, "감시에서 제거", 10, true);
                let _: () = msg_send![remove,setRepresentedObject:string(root)];
                let _: () = msg_send![parent,setSubmenu:submenu];
                let _: () = msg_send![submenu, release];
            }
        }
        add(self.menu, self.target, "폴더 추가…", 1, true);
        separator(self.menu);
        add(
            self.menu,
            self.target,
            if self.session.paused {
                "감시 재개"
            } else {
                "일시중지"
            },
            2,
            true,
        );
        add(self.menu, self.target, "다시 시작", 3, true);
        add(self.menu, self.target, "로그 폴더 열기", 4, true);
        let login = add(self.menu, self.target, "로그인 시 자동 실행", 5, true);
        let _: () = msg_send![login,setState:if self.login.enabled(){1isize}else{0isize}];
        add(self.menu, self.target, "로그인 항목 설정 열기", 6, true);
        add(
            self.menu,
            self.target,
            if self.updating {
                "업데이트 확인·준비 중…"
            } else {
                "업데이트 확인…"
            },
            7,
            !self.updating,
        );
        separator(self.menu);
        add(self.menu, self.target, "종료", 9, true);
        let button: Id = msg_send![self.item, button];
        let image: Id = msg_send![class!(NSImage),imageWithSystemSymbolName:string(if self.session.paused {"pause.circle"}else{"textformat.abc"}) accessibilityDescription:string("NameGuard")];
        if !image.is_null() {
            let _: () = msg_send![image,setTemplate:YES];
            let _: () = msg_send![button,setImage:image];
        } else {
            let _: () = msg_send![button,setTitle:string("NG")];
        }
        let _: () = msg_send![button,setToolTip:string(&format!("NameGuard · {title}"))];
    }
}
fn report(result: Result<()>) {
    if let Err(e) = result {
        APP.with(|a| {
            if let Some(app) = a.borrow_mut().as_mut() {
                app.session.error = e.to_string();
            }
        });
        alert("작업을 완료하지 못했습니다.", &e.to_string(), &["확인"]);
    }
    APP.with(|a| {
        if let Some(app) = a.borrow_mut().as_mut() {
            unsafe {
                app.refresh();
            }
        }
    });
}
fn quit() {
    APP.with(|a| {
        if let Some(app) = a.borrow_mut().as_mut() {
            app.session.stop();
        }
    });
    unsafe {
        let app: Id = msg_send![class!(NSApplication), sharedApplication];
        let _: () = msg_send![app,terminate:NIL];
    }
}
extern "C" fn will_terminate(_: &Object, _: Sel, _: Id) {
    APP.with(|a| {
        if let Some(app) = a.borrow_mut().as_mut() {
            app.session.stop();
        }
    });
}
extern "C" fn action(_: &Object, _: Sel, sender: Id) {
    unsafe {
        let pool: Id = msg_send![class!(NSAutoreleasePool), new];
        let tag: isize = msg_send![sender, tag];
        match tag {
            1 => {
                let folders = choose_folders();
                if !folders.is_empty() {
                    let result = APP.with(|a| {
                        a.borrow_mut()
                            .as_mut()
                            .unwrap()
                            .session
                            .change_roots(folders, None)
                    });
                    report(result);
                }
            }
            2 => {
                let result = APP.with(|a| a.borrow_mut().as_mut().unwrap().session.toggle_pause());
                report(result);
            }
            3 => {
                let result = APP.with(|a| a.borrow_mut().as_mut().unwrap().session.restart());
                report(result);
            }
            4 => APP.with(|a| open_folder(&a.borrow().as_ref().unwrap().session.directory)),
            5 => {
                let result = APP.with(|a| {
                    let borrow = a.borrow();
                    let app = borrow.as_ref().unwrap();
                    app.login.set(!app.login.enabled())
                });
                report(result);
            }
            6 => open_url("x-apple.systempreferences:com.apple.LoginItems-Settings.extension"),
            7 => {
                APP.with(|a| {
                    let mut borrow = a.borrow_mut();
                    let app = borrow.as_mut().unwrap();
                    if app.updating {
                        return;
                    }
                    let (tx, rx) = mpsc::channel();
                    app.rx = Some(rx);
                    app.updating = true;
                    thread::spawn(move || {
                        let _ = tx.send(Message::Checked(update::check()));
                    });
                    app.refresh();
                });
            }
            9 => quit(),
            10 => {
                let value: Id = msg_send![sender, representedObject];
                let root = PathBuf::from(text(value));
                let result = APP.with(|a| {
                    a.borrow_mut()
                        .as_mut()
                        .unwrap()
                        .session
                        .change_roots(vec![], Some(root))
                });
                report(result);
            }
            _ => {}
        }
        let _: () = msg_send![pool, drain];
    }
}
extern "C" fn tick(_: &Object, _: Sel, _: Id) {
    unsafe {
        let pool: Id = msg_send![class!(NSAutoreleasePool), new];
        if crate::STOP.load(Ordering::Relaxed) {
            quit();
            return;
        }
        let message = APP.with(|a| {
            let mut borrow = a.borrow_mut();
            let app = borrow.as_mut().unwrap();
            if !app.health_done && app.session.healthy() {
                if let Some(receipt) = &app.health {
                    if atomic(receipt, env!("CARGO_PKG_VERSION").as_bytes()).is_ok() {
                        app.health_done = true;
                    }
                }
            }
            app.refresh();
            app.rx.as_ref().and_then(|rx| rx.try_recv().ok())
        });
        match message {
            Some(Message::Checked(Ok(None))) => {
                APP.with(|a| a.borrow_mut().as_mut().unwrap().updating = false);
                alert(
                    "최신 버전입니다.",
                    &format!("현재 버전: {}", env!("CARGO_PKG_VERSION")),
                    &["확인"],
                );
            }
            Some(Message::Checked(Ok(Some(release)))) => {
                if alert(
                    &format!("NameGuard {}", release.version),
                    "새 버전을 다운로드할 수 있습니다. 감시 폴더와 설정은 유지됩니다.",
                    &["다운로드", "취소"],
                ) == 1000
                {
                    APP.with(|a| {
                        let mut borrow = a.borrow_mut();
                        let app = borrow.as_mut().unwrap();
                        let exe = app.session.executable.clone();
                        let dir = app.session.directory.clone();
                        let (tx, rx) = mpsc::channel();
                        app.rx = Some(rx);
                        thread::spawn(move || {
                            let _ =
                                tx.send(Message::Prepared(update::prepare(&exe, &dir, &release)));
                        });
                    });
                } else {
                    APP.with(|a| a.borrow_mut().as_mut().unwrap().updating = false);
                }
            }
            Some(Message::Prepared(Ok(staged))) => {
                if alert(
                    "다운로드 완료",
                    "재시작하면 업데이트를 설치합니다. 실행에 실패하면 기존 앱으로 복구합니다.",
                    &["재시작·설치", "취소"],
                ) == 1000
                {
                    match staged.install() {
                        Ok(()) => quit(),
                        Err(e) => {
                            staged.cancel();
                            alert("업데이트하지 못했습니다.", &e.to_string(), &["확인"]);
                        }
                    }
                } else {
                    staged.cancel();
                }
                APP.with(|a| a.borrow_mut().as_mut().unwrap().updating = false);
            }
            Some(Message::Checked(Err(e))) | Some(Message::Prepared(Err(e))) => {
                APP.with(|a| a.borrow_mut().as_mut().unwrap().updating = false);
                alert("업데이트하지 못했습니다.", &e.to_string(), &["확인"]);
            }
            None => {}
        }
        let _: () = msg_send![pool, drain];
    }
}
pub fn run(
    executable: PathBuf,
    directory: PathBuf,
    config: PathBuf,
    health: Option<PathBuf>,
) -> Result<()> {
    unsafe {
        let pool: Id = msg_send![class!(NSAutoreleasePool), new];
        let native: Id = msg_send![class!(NSApplication), sharedApplication];
        let _: BOOL = msg_send![native,setActivationPolicy:1isize];
        let session = Session::start(executable.clone(), directory.clone(), config)?;
        let login = Login {
            executable,
            directory,
            home: home(),
        };
        if let Err(e) = login.ensure() {
            eprintln!("NameGuard login: {e}");
        }
        let mut class = ClassDecl::new("NameGuardRustDelegate", class!(NSObject)).unwrap();
        class.add_method(sel!(action:), action as extern "C" fn(&Object, Sel, Id));
        class.add_method(sel!(tick:), tick as extern "C" fn(&Object, Sel, Id));
        class.add_method(
            sel!(applicationWillTerminate:),
            will_terminate as extern "C" fn(&Object, Sel, Id),
        );
        let target: Id = msg_send![class.register(), new];
        let _: () = msg_send![native,setDelegate:target];
        let bar: Id = msg_send![class!(NSStatusBar), systemStatusBar];
        let item: Id = msg_send![bar,statusItemWithLength:-1.0f64];
        let _: Id = msg_send![item, retain];
        let menu: Id = msg_send![class!(NSMenu), new];
        let _: () = msg_send![menu,setAutoenablesItems:NO];
        let _: () = msg_send![item,setMenu:menu];
        APP.with(|a| {
            *a.borrow_mut() = Some(App {
                session,
                login,
                item,
                menu,
                target,
                updating: false,
                rx: None,
                health,
                health_done: false,
            });
            a.borrow_mut().as_mut().unwrap().refresh();
        });
        let _: Id = msg_send![class!(NSTimer),scheduledTimerWithTimeInterval:2.0f64 target:target selector:sel!(tick:) userInfo:NIL repeats:YES];
        let _: () = msg_send![native, run];
        APP.with(|a| {
            a.borrow_mut().take();
        });
        let _: () = msg_send![menu, release];
        let _: () = msg_send![item, release];
        let _: () = msg_send![target, release];
        let _: () = msg_send![pool, drain];
        Ok(())
    }
}
